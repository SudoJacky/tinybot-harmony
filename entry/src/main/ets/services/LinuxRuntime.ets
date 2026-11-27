import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import native from 'libtinybot_sandbox.so';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { ToolFailure, ToolResultError } from '../model/ToolFailure';
import { Cancellation, RunCancelledError } from './Cancellation';
import { LinuxControl } from './LinuxControl';
import { writeBytes } from './FileBytes';
import { createLinuxDisks, LINUX_TREE_OFFSET, readLinuxResponse, resetLinuxDisk, writeLinuxRequest } from './LinuxExchange';
import { LinuxSerial, LinuxSerialEvents } from './LinuxSerial';
import { LinuxWorkspace, LinuxWorkspaceScope } from './LinuxWorkspace';
import { FileJobWorkspace } from './WorkspaceFiles';

const SETTINGS_KEY: string = 'settings';
const FILE_LIMIT: number = 1024 * 1024;
const GUEST_ASSETS: string[] = ['kernel', 'root-v5-shell.qcow2'];
const ASSET_CACHE: string = '/tinybot-linux-assets-v5-shell';
const EMBEDDED_CACHE: string = '/tinybot-linux-embedded-v3';
export const LINUX_TIMEOUTS: number[] = [30, 60, 120];
export const LINUX_MEMORY: number[] = [192, 256, 384];
export const MIN_LINUX_MEMORY: number = 192;
type LinuxStartup = 'on-demand' | 'prewarm';

export interface LinuxRuntimeSettings {
  readonly enabled: boolean;
  readonly allowInput: boolean;
  readonly allowOutput: boolean;
  readonly timeoutSeconds: number;
  readonly startup: LinuxStartup;
  readonly memoryMiB: number;
}

export interface LinuxRuntimeSettingsUpdate {
  enabled?: boolean;
  allowInput?: boolean;
  allowOutput?: boolean;
  timeoutSeconds?: number;
  startup?: LinuxStartup;
  memoryMiB?: number;
}

export interface LinuxJob {
  session?: string;
  language: string;
  source: string;
  inputPath?: string;
  outputPath?: string;
}

interface GuestRequest {
  language: string; source: string; collect: boolean; input?: string;
  projectBytes?: number; mountBytes?: number;
}
interface GuestResponse {
  exitCode: number; stdout: string; stderr: string; truncated: boolean; error?: string; artifact?: string;
  projectBytes?: number;
}
interface LinuxReceipt { exitCode: number; stdout: string; stderr: string; truncated: boolean; outputPath?: string; bytes?: number; }
type LinuxJobKind = 'tool' | 'warm-up';
type LinuxJobOutcome = 'complete' | 'failed' | 'cancelled';

export interface LinuxJobStatus {
  kind: LinuxJobKind;
  outcome: LinuxJobOutcome;
  elapsedMs: number;
  startedAt: number;
  error: string;
}

export interface LinuxRuntimeSnapshot {
  available: boolean;
  ready: boolean;
  saving: boolean;
  separateProcess: boolean;
  active?: LinuxJobKind;
  stopping: boolean;
  terminalInUse: boolean;
  fault: string;
  settingsError: string;
  history: LinuxJobStatus[];
  assetsReady: boolean;
  memoryInUse?: number;
  memoryLimit: number;
  settings: LinuxRuntimeSettings;
}

class LinuxRuntime {
  private settings: LinuxRuntimeSettings = {
    enabled: true, allowInput: true, allowOutput: true, timeoutSeconds: 120, startup: 'on-demand', memoryMiB: 192
  };
  private store?: preferences.Preferences;
  private saving: boolean = false;
  private settingsError: string = '';
  private active?: LinuxJobKind;
  private signal?: Cancellation;
  private history: LinuxJobStatus[] = [];
  private assetsReady: boolean = false;
  private memoryInUse?: number;
  private memoryLimit: number = 0;
  private boot?: Promise<void>;
  private starting: boolean = false;
  private terminalInUse: boolean = false;
  private fault: string = '';
  private startupResult?: (error?: Error) => void;
  private terminals: Set<LinuxSerialEvents> = new Set<LinuxSerialEvents>();
  private transcript: Uint8Array[] = [];
  private transcriptBytes: number = 0;
  private listeners: Set<() => void> = new Set<() => void>();
  private control: LinuxControl = new LinuxControl((error) => this.fail(error));
  private serial: LinuxSerial = new LinuxSerial({
    ready: () => this.startupResult?.(),
    output: (bytes) => this.recordOutput(bytes),
    failed: (error) => this.fail(error)
  });

  get available(): boolean { return typeof native.startLinuxChild === 'function'; }
  get toolEnabled(): boolean {
    return this.available && this.store !== undefined && this.settings.enabled && !this.fault;
  }

  private get separateProcess(): boolean { return deviceInfo.deviceType === 'tablet' || deviceInfo.deviceType === '2in1'; }

  initialize(context: common.Context): void {
    if (!this.available || this.store) { return; }
    try {
      const store = preferences.getPreferencesSync(context, { name: 'tinybot-linux-runtime' });
      const value = store.getSync(SETTINGS_KEY, JSON.stringify(this.settings));
      if (typeof value !== 'string') { throw new Error(t('Linux 沙盒配置无效。')); }
      const saved = JSON.parse(value) as LinuxRuntimeSettings;
      if (!saved) { throw new Error(t('Linux 沙盒配置无效。')); }
      const settings: LinuxRuntimeSettings = {
        enabled: saved.enabled, allowInput: saved.allowInput, allowOutput: saved.allowOutput,
        timeoutSeconds: saved.timeoutSeconds, startup: saved.startup ?? 'on-demand', memoryMiB: saved.memoryMiB ?? 192
      };
      this.validate(settings);
      this.memoryLimit = native.linuxMemoryLimit();
      this.settings = settings;
      this.store = store;
      this.settingsError = '';
    } catch (error) {
      const failure = error as Error;
      this.settingsError = failure.message;
      Diagnostics.log('warn', 'linux-runtime', 'settings_load_failed', {}, failure);
    }
  }

  snapshot(): LinuxRuntimeSnapshot {
    return { available: this.available, ready: this.store !== undefined, saving: this.saving, separateProcess: this.separateProcess,
      terminalInUse: this.terminalInUse, active: this.active ?? (this.starting ? 'warm-up' : undefined), stopping: this.signal?.cancelled === true, fault: this.fault, settingsError: this.settingsError,
      history: this.history, assetsReady: this.assetsReady, memoryInUse: this.memoryInUse,
      memoryLimit: this.memoryLimit, settings: this.settings };
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  private publish(): void { this.listeners.forEach((listener) => listener()); }

  private validate(settings: LinuxRuntimeSettings): void {
    if (!settings || typeof settings.enabled !== 'boolean' || typeof settings.allowInput !== 'boolean' ||
      typeof settings.allowOutput !== 'boolean' || !LINUX_TIMEOUTS.includes(settings.timeoutSeconds) ||
      !Number.isSafeInteger(settings.memoryMiB) || settings.memoryMiB < MIN_LINUX_MEMORY ||
      (settings.startup !== 'on-demand' && settings.startup !== 'prewarm')) {
      throw new Error(t('Linux 沙盒配置无效。'));
    }
  }

  private validateMemory(memory: number): void {
    if (!Number.isSafeInteger(memory) || memory < MIN_LINUX_MEMORY || memory > this.memoryLimit) {
      throw new Error(t('请输入 {0} 到 {1} MiB 之间的整数。', [MIN_LINUX_MEMORY, this.memoryLimit]));
    }
  }

  async save(update: LinuxRuntimeSettingsUpdate): Promise<void> {
    const store = this.store;
    if (!store) { throw new Error(t('无法读取 Linux 沙盒配置。')); }
    const settings: LinuxRuntimeSettings = {
      enabled: update.enabled ?? this.settings.enabled,
      allowInput: update.allowInput ?? this.settings.allowInput,
      allowOutput: update.allowOutput ?? this.settings.allowOutput,
      timeoutSeconds: update.timeoutSeconds ?? this.settings.timeoutSeconds,
      startup: update.startup ?? this.settings.startup,
      memoryMiB: update.memoryMiB ?? this.settings.memoryMiB
    };
    if (update.memoryMiB !== undefined) { this.validateMemory(update.memoryMiB); }
    this.validate(settings);
    await this.editWorkspace(async () => {
      const changePower = settings.enabled !== this.settings.enabled && this.memoryInUse !== undefined && !this.fault;
      if (changePower) { await this.control.setRunning(settings.enabled); }
      try {
        store.putSync(SETTINGS_KEY, JSON.stringify(settings));
        await store.flush();
      }
      catch (error) {
        try { store.putSync(SETTINGS_KEY, JSON.stringify(this.settings)); }
        finally { if (changePower) { await this.control.setRunning(this.settings.enabled); } }
        throw error as Error;
      }
      this.settings = settings;
      if (!settings.enabled) { this.terminals.forEach((view) => view.failed(new Error(t('已停用')))); }
    });
  }

  async editWorkspace(change: () => Promise<void>): Promise<void> {
    if (this.starting || this.active || this.saving) { throw new Error(t('请等待当前沙盒操作结束。')); }
    this.saving = true;
    try { this.publish(); await change(); }
    catch (error) {
      Diagnostics.log('warn', 'linux-runtime', 'settings_save_failed', {}, error as Error);
      throw error as Error;
    } finally {
      this.saving = false;
      this.publish();
    }
  }

  stop(): void { this.signal?.cancel(); }

  async prewarmOnStartup(context: common.Context): Promise<void> {
    if (this.toolEnabled && this.settings.startup === 'prewarm') { await this.warmUp(context); }
  }

  warmUp(context: common.Context): Promise<void> {
    if (!this.toolEnabled || this.saving) {
      return Promise.reject(new ToolFailure('TOOL_UNAVAILABLE', this.fault || t('Linux 沙盒不可用或已停用。'), 'inspect_error'));
    }
    if (!this.boot) { this.boot = this.bootGuest(context); }
    return this.boot;
  }

  private fail(error: Error): void {
    if (this.fault) { return; }
    this.fault = error.message || String(error);
    this.startupResult?.(error);
    this.serial.fail(error);
    this.terminals.forEach((view) => view.failed(error));
    Diagnostics.log('warn', 'linux-runtime', 'guest_failed', {}, error);
    this.publish();
  }

  private async bootGuest(context: common.Context): Promise<void> {
    const started = Date.now();
    const dir = context.cacheDir + EMBEDDED_CACHE;
    const memory = this.settings.memoryMiB;
    this.starting = true;
    let childId: string = '';
    let timer: number = -1;
    try {
      this.publish();
      this.validateMemory(memory);
      const startup = new Cancellation();
      await this.stageAssets(context, startup);
      if (await fs.access(dir)) { await fs.rmdir(dir); }
      await fs.mkdir(dir);
      await createLinuxDisks(dir, native.linuxStorageBytes(context.cacheDir));
      if (this.separateProcess) {
        childId = util.generateRandomUUID();
        native.startLinuxChild(childId, dir, memory).then(() => {
          this.fail(new Error('Linux child exited'));
        }, (error: Error) => this.fail(error));
      } else { native.startEmbeddedLinux(dir, memory); }
      await this.control.connect(dir);
      await this.serial.connect(dir + '/tty', startup, () => !!this.fault);
      const ready = new Promise<void>((resolve, reject) => {
        this.startupResult = (error?: Error): void => { if (error) { reject(error); } else { resolve(); } };
        timer = setTimeout(() => reject(new Error(t('Linux 控制台启动超时。'))), 45000);
      });
      await Promise.all([ready, this.control.setRunning(true)]);
      if (this.fault) { throw new Error(this.fault); }
      this.memoryInUse = memory;
      Diagnostics.log('info', 'linux-runtime', 'guest_ready', { elapsedMs: Date.now() - started });
    } catch (error) {
      this.fail(error as Error);
      if (childId) { native.cancelLinux(childId); }
      await this.serial.close();
      throw error as Error;
    } finally {
      clearTimeout(timer);
      this.startupResult = undefined;
      this.starting = false;
      const status: LinuxJobStatus = { kind: 'warm-up', startedAt: started, elapsedMs: Date.now() - started,
        outcome: this.fault ? 'failed' : 'complete', error: this.fault };
      this.history = [status].concat(this.history.slice(0, 11));
      this.publish();
    }
  }

  private recordOutput(bytes: Uint8Array): void {
    this.transcript.push(bytes);
    this.transcriptBytes += bytes.length;
    while (this.transcriptBytes > 256 * 1024 || this.transcript.length > 4096) {
      this.transcriptBytes -= this.transcript.shift()!.length;
    }
    this.terminals.forEach((view) => view.output(bytes));
  }

  async runConsole(context: common.Context, events: LinuxSerialEvents, signal: Cancellation): Promise<void> {
    signal.check();
    await this.warmUp(context);
    signal.check();
    this.terminals.add(events);
    try {
      events.ready();
      this.transcript.forEach((bytes) => events.output(bytes, true));
      await new Promise<void>((resolve) => signal.onCancel(resolve));
    } finally { this.terminals.delete(events); }
  }

  input(text: string): Promise<void> { return this.settings.enabled ? this.serial.input(text) : Promise.resolve(); }
  resize(columns: number, rows: number): Promise<void> { return this.serial.resize(columns, rows); }

  async imageSize(context: common.Context): Promise<number> {
    let total = 0;
    for (const name of GUEST_ASSETS) {
      const path = 'linux/' + name;
      const file = await context.resourceManager.getRawFd(path);
      try { total += file.length; }
      finally { await context.resourceManager.closeRawFd(path); }
    }
    return total;
  }

  runTool(context: common.Context, job: LinuxJob, files: FileJobWorkspace, parent: Cancellation,
    scope?: LinuxWorkspaceScope): Promise<LinuxReceipt> {
    return this.withRuntime<LinuxReceipt>(parent, async (signal) => {
      if (job.inputPath !== undefined && (!this.settings.allowInput || !files)) {
        throw new ToolFailure('PERMISSION_DENIED', t('Linux 沙盒未获准从工作区导入文件。'), 'check_permissions');
      }
      if (job.outputPath !== undefined && (!this.settings.allowOutput || !files)) {
        throw new ToolFailure('PERMISSION_DENIED', t('Linux 沙盒未获准向工作区导出文件。'), 'check_permissions');
      }
      return this.execute(context, job, signal, files, scope);
    });
  }

  private async withRuntime<T>(parent: Cancellation,
    operation: (signal: Cancellation) => Promise<T>): Promise<T> {
    parent.check();
    if (!this.available || !this.store || !this.settings.enabled) {
      throw new ToolFailure('TOOL_UNAVAILABLE', t('Linux 沙盒不可用或已停用。'), 'check_available_tools');
    }
    if (this.fault) { throw new ToolFailure('EXECUTION_FAILED', this.fault, 'inspect_error'); }
    if (this.active || this.saving) { throw new ToolFailure('BUSY', t('请等待当前沙盒操作结束。'), 'wait_then_check'); }
    this.validateMemory(this.memoryInUse ?? this.settings.memoryMiB);
    const signal = new Cancellation();
    const stopUpdates = signal.onCancel(() => this.publish());
    const disconnect = parent.onCancel(() => signal.cancel());
    const started = Date.now();
    this.signal = signal;
    this.active = 'tool';
    let outcome: LinuxJobOutcome = 'complete';
    let message: string = '';
    try {
      this.publish();
      return await operation(signal);
    } catch (error) {
      const failure = error as Error;
      outcome = failure instanceof RunCancelledError ? 'cancelled' : 'failed';
      if (outcome === 'failed') {
        message = failure.message.slice(0, 500);
        Diagnostics.log('warn', 'linux-runtime', 'job_failed', { elapsedMs: Date.now() - started,
          isolated: this.separateProcess, timeoutSeconds: this.settings.timeoutSeconds }, failure);
      }
      throw failure;
    } finally {
      disconnect();
      stopUpdates();
      const result: LinuxJobStatus = { kind: 'tool', outcome: outcome, elapsedMs: Date.now() - started,
        startedAt: started, error: message };
      this.history = [result].concat(this.history.slice(0, 11));
      this.active = undefined;
      this.signal = undefined;
      this.publish();
    }
  }

  private async stageAssets(context: common.Context, signal: Cancellation): Promise<void> {
    const dir = context.cacheDir + ASSET_CACHE;
    if (this.assetsReady && await fs.access(dir + '/' + GUEST_ASSETS[0]) && await fs.access(dir + '/' + GUEST_ASSETS[1])) { return; }
    this.assetsReady = false;
    if (!await fs.access(dir)) { await fs.mkdir(dir); }
    for (const name of GUEST_ASSETS) {
      signal.check();
      const bytes = await context.resourceManager.getRawFileContent('linux/' + name);
      await writeBytes(dir + '/' + name, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length));
    }
    this.assetsReady = true;
  }

  private async execute(context: common.Context, job: LinuxJob, signal: Cancellation, files?: FileJobWorkspace,
    scope?: LinuxWorkspaceScope): Promise<LinuxReceipt> {
    const request: GuestRequest = { language: job.language, source: job.source, collect: job.outputPath !== undefined };
    if (job.inputPath !== undefined && files) {
      const bytes = await files.readJobInput(job.inputPath, FILE_LIMIT, signal);
      request.input = bytes.length > 0 ? new util.Base64Helper().encodeToStringSync(bytes) : '';
    }
    const shared = job.session !== 'workspace' && job.inputPath === undefined && job.outputPath === undefined;
    const workspace = !shared && scope ? new LinuxWorkspace(context, scope) : undefined;
    await this.warmUp(context);
    signal.check();
    const dir = context.cacheDir + EMBEDDED_CACHE;
    const disk = await fs.open(dir + '/exchange', fs.OpenMode.READ_WRITE);
    const fd = disk.fd;
    try {
      if (scope && workspace && this.settings.allowInput) {
        const config = await workspace.config();
        if (scope.project && config.persistent && this.settings.allowOutput) {
          request.projectBytes = await workspace.packProject(fd, signal);
        }
        if (config.mounts.length > 0) {
          request.mountBytes = await workspace.packMounts(config.mounts, fd, LINUX_TREE_OFFSET + (request.projectBytes ?? 0), signal);
        }
      }
      signal.check();
      await writeLinuxRequest(fd, JSON.stringify(request));
      signal.check();
      this.terminalInUse = shared;
      try { this.publish(); await this.serial.runJob(signal, this.settings.timeoutSeconds, shared); }
      finally { this.terminalInUse = false; this.publish(); }
      signal.check();
      const json = await readLinuxResponse(fd);
      return await this.finishJob(json, request, job, signal, fd, files, workspace);
    } finally {
      try {
        if (!this.fault) {
          await resetLinuxDisk(fd);
          if (request.projectBytes !== undefined || request.mountBytes !== undefined) {
            const scratch = await fs.open(dir + '/workspace', fs.OpenMode.READ_WRITE);
            try { await resetLinuxDisk(scratch.fd); } finally { await fs.close(scratch); }
          }
        }
      } finally { await fs.close(disk); }
    }
  }

  private async finishJob(json: string, request: GuestRequest, job: LinuxJob, signal: Cancellation, fd: number,
    files?: FileJobWorkspace, workspace?: LinuxWorkspace): Promise<LinuxReceipt> {
    const result = JSON.parse(json) as GuestResponse;
    if (result.error) { throw new ToolFailure('EXECUTION_FAILED', result.error, 'fix_code'); }
    if (!Number.isInteger(result.exitCode) || typeof result.stdout !== 'string' || typeof result.stderr !== 'string' ||
      typeof result.truncated !== 'boolean') {
      throw new ToolFailure('INVALID_RESPONSE', 'Invalid Linux result.', 'inspect_result_before_retry');
    }
    const receipt: LinuxReceipt = { exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr, truncated: result.truncated };
    if (receipt.exitCode !== 0) { throw new ToolResultError(JSON.stringify(receipt), 'EXECUTION_FAILED', 'fix_code'); }
    if (request.projectBytes !== undefined && (result.projectBytes === undefined || !Number.isSafeInteger(result.projectBytes) ||
      result.projectBytes < 0 || result.projectBytes > (await fs.stat(fd)).size - LINUX_TREE_OFFSET)) {
      throw new ToolFailure('INVALID_RESPONSE', 'Missing Linux project snapshot.', 'inspect_result_before_retry');
    }
    let output: Uint8Array | undefined;
    if (job.outputPath !== undefined && files) {
      if (typeof result.artifact !== 'string') { throw new ToolFailure('INVALID_RESPONSE', 'Missing Linux output.', 'inspect_result_before_retry'); }
      output = result.artifact.length ? new util.Base64Helper().decodeSync(result.artifact) : new Uint8Array(0);
      if (output.length > FILE_LIMIT) { throw new ToolFailure('LIMIT_EXCEEDED', 'Linux output exceeds 1 MiB.', 'reduce_input'); }
    }
    const publishOutput = async (): Promise<void> => {
      if (job.outputPath !== undefined && files && output !== undefined) {
        await files.createJobOutput(job.outputPath, output, signal);
        receipt.outputPath = job.outputPath;
        receipt.bytes = output.length;
      }
    };
    if (request.projectBytes !== undefined && workspace && result.projectBytes !== undefined) {
      await workspace.saveProject(fd, result.projectBytes, signal, publishOutput);
    } else {
      await publishOutput();
    }
    return receipt;
  }
}

export const linuxRuntime: LinuxRuntime = new LinuxRuntime();
