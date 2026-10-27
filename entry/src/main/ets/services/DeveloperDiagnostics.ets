import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { taskpool, util } from '@kit.ArkTS';
import { displaySync } from '@kit.ArkGraphics2D';
import { hidebug, hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { Diagnostics, PerfEvent, PerfSnapshot } from '../model/Diagnostics';
import { collectPerformanceResources, ResourceProbe } from './PerformanceProbe';
import { readAppInformation, AppInformation } from './AppInformation';
import { clearRecentDiagnosticLogs, configureNativeDiagnosticLog } from './NativeDiagnosticLog';

interface HeapProbe { usedKiB: number; totalKiB: number; arraysKiB: number; }
interface TraceEntry { name: string; cat: string; ph: string; ts: number; dur?: number; pid: number; tid: number; args: Record<string, Object>; s?: string; }
interface DiagnosticExport {
  schema: number; application: AppInformation; platform: string; clock: string; definitions: string[];
  capture: PerfSnapshot; traceEvents: TraceEntry[]; displayTimeUnit: string; journal: string; previousJournal: string; diagnosticError: string;
}

export class DeveloperDiagnostics {
  private static store?: preferences.Preferences;
  private static context?: common.Context;
  private static unlocked: boolean = false;
  private static foreground: boolean = false;
  private static timer: number = -1;
  private static frames?: displaySync.DisplaySync;
  private static frameEnabled: boolean = false;
  private static lastFrame: number = 0;
  private static deadline: number = 0;
  private static ticks: number = 0;
  private static sampling: boolean = false;
  private static writing: Promise<void> = Promise.resolve();
  private static journalBusy: boolean = false;
  private static journalSequence: number = 0;
  private static journalSession: number = -1;
  private static journalBytes: number = 0;
  private static marker: number = 0;
  private static watcher?: hiAppEvent.Watcher;
  private static cpuProfile: boolean = false;
  private static cpuTimer: number = -1;

  static initialize(context: common.Context): void {
    configureNativeDiagnosticLog();
    DeveloperDiagnostics.context = context;
    Diagnostics.configureClock(() => systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000);
    try {
      DeveloperDiagnostics.store = preferences.getPreferencesSync(context, { name: 'tinybot-developer' });
      DeveloperDiagnostics.unlocked = DeveloperDiagnostics.store.getSync('enabled', false) === true;
    } catch (error) { DeveloperDiagnostics.fail(1, error as Error); }
    AppStorage.setOrCreate('tinybot.developer.enabled', DeveloperDiagnostics.unlocked);
    AppStorage.setOrCreate('tinybot.developer.recording', false);
  }
  static enable(): void {
    DeveloperDiagnostics.persist(true);
    DeveloperDiagnostics.start();
  }
  private static persist(enabled: boolean): void {
    const store = DeveloperDiagnostics.store;
    if (!store) { throw new Error('Developer preference storage is unavailable.'); }
    try { store.putSync('enabled', enabled); store.flushSync(); }
    catch (error) { store.putSync('enabled', DeveloperDiagnostics.unlocked); throw error as Error; }
    DeveloperDiagnostics.unlocked = enabled; AppStorage.setOrCreate('tinybot.developer.enabled', enabled);
  }
  static disable(): void { DeveloperDiagnostics.persist(false); DeveloperDiagnostics.stop(); }
  static start(): void {
    if (!DeveloperDiagnostics.unlocked || Diagnostics.recording) { return; }
    AppStorage.setOrCreate('tinybot.developer.error', '');
    Diagnostics.start(); DeveloperDiagnostics.marker = 0;
    Diagnostics.log('info', 'diagnostics', 'started');
    AppStorage.setOrCreate('tinybot.developer.recording', true);
    DeveloperDiagnostics.watch(); DeveloperDiagnostics.resume();
  }
  static stop(): void {
    try { DeveloperDiagnostics.stopCpuProfile(); } catch (error) { DeveloperDiagnostics.fail(7, error as Error); }
    if (Diagnostics.recording) { Diagnostics.log('info', 'diagnostics', 'stopped'); }
    DeveloperDiagnostics.suspend(); Diagnostics.stop();
    AppStorage.setOrCreate('tinybot.developer.recording', false);
    DeveloperDiagnostics.flush();
    if (DeveloperDiagnostics.watcher) {
      try { hiAppEvent.removeWatcher(DeveloperDiagnostics.watcher); }
      catch (error) { DeveloperDiagnostics.fail(2, error as Error); }
      DeveloperDiagnostics.watcher = undefined;
    }
  }
  static setForeground(foreground: boolean): void {
    DeveloperDiagnostics.foreground = foreground;
    if (!foreground) { try { DeveloperDiagnostics.stopCpuProfile(); } catch (error) { DeveloperDiagnostics.fail(7, error as Error); } }
    if (!Diagnostics.recording) { return; }
    Diagnostics.event(foreground ? 'lifecycle.foreground' : 'lifecycle.background', {}, 0, true);
    if (foreground) { DeveloperDiagnostics.resume(); }
    else { DeveloperDiagnostics.suspend(); DeveloperDiagnostics.flush(); }
  }
  static setFrames(enabled: boolean): void {
    DeveloperDiagnostics.frameEnabled = enabled;
    Diagnostics.event('sampling.frames', { enabled: enabled ? 1 : 0 }, 0, true);
    DeveloperDiagnostics.syncFrames();
  }
  static framesEnabled(): boolean { return DeveloperDiagnostics.frameEnabled; }
  static startCpuProfile(): void {
    if (!DeveloperDiagnostics.unlocked || !DeveloperDiagnostics.foreground || DeveloperDiagnostics.cpuProfile) { return; }
    hidebug.startJsCpuProfiling('tinybot-cpu');
    DeveloperDiagnostics.cpuProfile = true; AppStorage.setOrCreate('tinybot.developer.cpu', true);
    Diagnostics.event('profiler.cpuStart', {}, 0, true);
    DeveloperDiagnostics.cpuTimer = setTimeout(() => {
      try { DeveloperDiagnostics.stopCpuProfile(); } catch (error) { DeveloperDiagnostics.fail(7, error as Error); }
    }, 30000);
  }
  static stopCpuProfile(): void {
    clearTimeout(DeveloperDiagnostics.cpuTimer); DeveloperDiagnostics.cpuTimer = -1;
    if (!DeveloperDiagnostics.cpuProfile) { return; }
    hidebug.stopJsCpuProfiling(); DeveloperDiagnostics.cpuProfile = false;
    AppStorage.setOrCreate('tinybot.developer.cpu', false); Diagnostics.event('profiler.cpuStop', {}, 0, true);
  }
  static cpuProfilePath(): string {
    DeveloperDiagnostics.stopCpuProfile();
    if (!DeveloperDiagnostics.context) { throw new Error('Diagnostic storage is unavailable.'); }
    // HiDebug writes to application filesDir, not the EntryAbility/module filesDir.
    return DeveloperDiagnostics.context.getApplicationContext().filesDir + '/tinybot-cpu.json';
  }
  static mark(): void {
    Diagnostics.event('user.marker', { number: ++DeveloperDiagnostics.marker }, 0, true);
    if (Diagnostics.acceptsLog('info')) { Diagnostics.log('info', 'diagnostics', 'marker', { count: DeveloperDiagnostics.marker }); }
  }
  private static resume(): void {
    if (!Diagnostics.recording || !DeveloperDiagnostics.foreground || DeveloperDiagnostics.timer !== -1) { return; }
    DeveloperDiagnostics.deadline = Diagnostics.now() + 250;
    DeveloperDiagnostics.timer = setInterval(() => DeveloperDiagnostics.tick(), 250);
    DeveloperDiagnostics.sample(); DeveloperDiagnostics.syncFrames();
  }
  private static suspend(): void {
    clearInterval(DeveloperDiagnostics.timer); DeveloperDiagnostics.timer = -1;
    DeveloperDiagnostics.stopFrames();
  }
  private static tick(): void {
    const now = Diagnostics.now();
    const lag = Math.max(0, now - DeveloperDiagnostics.deadline); DeveloperDiagnostics.deadline = now + 250;
    Diagnostics.measure('ui.eventLoopDelay', lag);
    if (lag >= 16.7) { Diagnostics.event('ui.eventLoopDelay', { delayMs: lag }, 0, true); }
    if (++DeveloperDiagnostics.ticks % 4 === 0) { DeveloperDiagnostics.sample(); }
    if (DeveloperDiagnostics.ticks % 20 === 0) { DeveloperDiagnostics.flush(); }
  }
  private static async sample(): Promise<void> {
    if (DeveloperDiagnostics.sampling || !Diagnostics.recording) { return; }
    DeveloperDiagnostics.sampling = true;
    const mark = Diagnostics.begin();
    try {
      // VM data must describe the UI VM, not the taskpool worker VM.
      const vm = hidebug.getAppVMMemoryInfo();
      const heap: HeapProbe = { usedKiB: Number(vm.heapUsed), totalKiB: Number(vm.totalHeap), arraysKiB: Number(vm.allArraySize) };
      const resource = await taskpool.execute(collectPerformanceResources) as ResourceProbe;
      if (!Diagnostics.recording || !mark || mark.session !== Diagnostics.session || !DeveloperDiagnostics.foreground) { return; }
      if (resource.error !== 0) { DeveloperDiagnostics.fail(3, new Error('Resource probe failed'), resource.error); }
      Diagnostics.measure('memory.vmUsed', heap.usedKiB, 'KiB'); Diagnostics.measure('memory.vmTotal', heap.totalKiB, 'KiB');
      if (resource.pss >= 0) { Diagnostics.measure('memory.pssSwap', resource.pss, 'KiB'); Diagnostics.measure('memory.rss', resource.rss, 'KiB'); }
      if (resource.cpu >= 0) { Diagnostics.measure('cpu.process', resource.cpu, '%'); }
      Diagnostics.event('resource.process', { pssSwapKiB: resource.pss, rssKiB: resource.rss, vssKiB: resource.vss,
        privateDirtyKiB: resource.privateDirty, sharedDirtyKiB: resource.sharedDirty, cpuPercent: resource.cpu,
        vmUsedKiB: heap.usedKiB, vmTotalKiB: heap.totalKiB, vmArraysKiB: heap.arraysKiB, threadsReported: resource.threads.length }, 0, true);
      resource.threads.forEach((thread) => { Diagnostics.event('resource.thread', { cpuPercent: thread.cpu }, thread.id, true); });
      Diagnostics.end('diagnostics.resourceProbe', mark);
    } catch (error) { DeveloperDiagnostics.fail(3, error as Error); }
    finally { DeveloperDiagnostics.sampling = false; }
  }
  private static stopFrames(): void {
    const frames = DeveloperDiagnostics.frames; DeveloperDiagnostics.frames = undefined; DeveloperDiagnostics.lastFrame = 0;
    if (frames) {
      try { frames.stop(); frames.off('frame'); }
      catch (error) { DeveloperDiagnostics.fail(4, error as Error); }
    }
  }
  private static syncFrames(): void {
    DeveloperDiagnostics.stopFrames();
    if (!Diagnostics.recording || !DeveloperDiagnostics.foreground || !DeveloperDiagnostics.frameEnabled) { return; }
    try {
      const frames = displaySync.create(); DeveloperDiagnostics.frames = frames;
      frames.on('frame', (frame: displaySync.IntervalInfo) => {
        const now = Diagnostics.now();
        if (DeveloperDiagnostics.lastFrame > 0) { Diagnostics.measure('ui.frameCallbackInterval', now - DeveloperDiagnostics.lastFrame); }
        DeveloperDiagnostics.lastFrame = now;
        Diagnostics.measure('ui.vsyncPeriod', (frame.targetTimestamp - frame.timestamp) / 1000000);
      });
      frames.start();
    } catch (error) { DeveloperDiagnostics.stopFrames(); DeveloperDiagnostics.fail(4, error as Error); }
  }
  private static watch(): void {
    try {
      const watcher: hiAppEvent.Watcher = { name: 'TinybotPerformance', appEventFilters: [{ domain: hiAppEvent.domain.OS,
        names: [hiAppEvent.event.MAIN_THREAD_JANK, hiAppEvent.event.APP_FREEZE, hiAppEvent.event.APP_CRASH, hiAppEvent.event.RESOURCE_OVERLIMIT] }],
        onReceive: (_domain: string, groups: hiAppEvent.AppEventGroup[]) => {
          groups.forEach((group: hiAppEvent.AppEventGroup) => {
            // Export event names and numbers only, never system stack text, paths or arbitrary params.
            group.appEventInfos.forEach((event: hiAppEvent.AppEventInfo) => {
              const values: Record<string, number> = {};
              ['time', 'begin_time', 'end_time', 'duration', 'pid', 'tid', 'happen_time'].forEach((key: string) => {
                const value: Object = event.params[key]; if (typeof value === 'number') { values[key] = value; }
              });
              Diagnostics.event('os.' + group.name, values, 0, true);
            });
          });
        } };
      const holder = hiAppEvent.addWatcher(watcher);
      if (!holder) { throw new Error('System event watcher unavailable.'); }
      DeveloperDiagnostics.watcher = watcher;
    } catch (error) { DeveloperDiagnostics.fail(5, error as Error); }
  }
  private static fail(source: number, error: Error, probeCode?: number): void {
    const code = probeCode === undefined ? (error as BusinessError).code || -1 : probeCode;
    AppStorage.setOrCreate('tinybot.developer.error', 'Diagnostics ' + source + ' / ' + code);
    Diagnostics.event('diagnostics.error', { source: source, code: code }, 0, true);
    Diagnostics.log('error', 'diagnostics', 'failed', { code: code, operationId: source });
  }
  private static path(previous: boolean = false): string {
    if (!DeveloperDiagnostics.context) { throw new Error('Diagnostic storage is unavailable.'); }
    return DeveloperDiagnostics.context.filesDir + (previous ? '/performance-previous.jsonl' : '/performance-current.jsonl');
  }
  private static async rotate(): Promise<void> {
    const path = DeveloperDiagnostics.path(); const previous = DeveloperDiagnostics.path(true);
    if (await fs.access(path)) { if (await fs.access(previous)) { await fs.unlink(previous); } await fs.rename(path, previous); }
    DeveloperDiagnostics.journalBytes = 0;
  }
  private static async writeAll(fd: number, text: string): Promise<number> {
    const bytes = new util.TextEncoder().encodeInto(text);
    let written = 0;
    while (written < bytes.byteLength) {
      const count = await fs.write(fd, bytes.buffer.slice(written));
      if (count <= 0) { throw new Error('Diagnostic file write did not complete.'); }
      written += count;
    }
    return written;
  }
  static flush(): void {
    if (DeveloperDiagnostics.journalBusy || Diagnostics.session === 0) { return; }
    const snapshot = Diagnostics.snapshot(false); const events = Diagnostics.eventsSince(DeveloperDiagnostics.journalSession === Diagnostics.session ? DeveloperDiagnostics.journalSequence : 0);
    if (events.length === 0 && DeveloperDiagnostics.journalSession === Diagnostics.session) { return; }
    DeveloperDiagnostics.journalBusy = true;
    const session = Diagnostics.session; const sequence = events.length ? events[events.length - 1].seq : 0;
    const text = JSON.stringify({ type: 'statistics', capture: snapshot }) + '\n' + events.map((event: PerfEvent) => JSON.stringify(event)).join('\n') + '\n';
    DeveloperDiagnostics.writing = DeveloperDiagnostics.writing.then(async () => {
      if (DeveloperDiagnostics.journalSession !== session || DeveloperDiagnostics.journalBytes + text.length > 4 * 1024 * 1024) { await DeveloperDiagnostics.rotate(); }
      const file = await fs.open(DeveloperDiagnostics.path(), fs.OpenMode.CREATE | fs.OpenMode.APPEND | fs.OpenMode.WRITE_ONLY);
      try { DeveloperDiagnostics.journalBytes += await DeveloperDiagnostics.writeAll(file.fd, text); } finally { await fs.close(file); }
      DeveloperDiagnostics.journalSession = session; DeveloperDiagnostics.journalSequence = sequence;
    }).catch((error: Error) => DeveloperDiagnostics.fail(6, error)).finally(() => { DeveloperDiagnostics.journalBusy = false; });
  }
  private static async readJournal(previous: boolean): Promise<string> {
    const path = DeveloperDiagnostics.path(previous);
    return await fs.access(path) ? await fs.readText(path) : '';
  }
  static async exportCapture(context: common.UIAbilityContext): Promise<string> {
    // Pause capture during serialization so export latency cannot masquerade as application work.
    DeveloperDiagnostics.stop(); await DeveloperDiagnostics.writing;
    DeveloperDiagnostics.flush(); await DeveloperDiagnostics.writing;
    const snapshot = Diagnostics.snapshot();
    const data: DiagnosticExport = { schema: 2, application: readAppInformation(), platform: 'HarmonyOS', clock: 'monotonic startup milliseconds',
      diagnosticError: AppStorage.get<string>('tinybot.developer.error') || '',
      definitions: ['memory.pssSwap = HiDebug PSS + SwapPss, KiB; RSS is separate; current process only.',
        'CPU = HiDebug process/thread usage percent; worker probe overhead included; top 32 threads.',
        'VM heap is UI VM only. Sampling nominal 1 s in foreground; missed ticks are not interpolated.',
        'ui.eventLoopDelay = 250 ms timer lateness; ui.frameCallbackInterval = optional displaySync callback interval, neither is an official dropped-frame rate.',
        'Percentiles are histogram upper bounds; histogram boundaries: 0.1,0.5,1,2,4,8,16.7,33.4,50,100,250,500,1000,5000,30000,infinity.',
        'Time-only correlation between renderer view IDs and network request IDs; IDs are local numeric identities, not conversation IDs.',
        'chars = UTF-16 code units (ArkTS string.length); transport bytes are counted separately.',
        'Runtime logs have level/module/event/fields. Names and string values are allowlisted; arbitrary error text, bodies, URLs and paths are excluded. Reference ordinals reset each capture.',
        'Runtime logs keep the latest 1000 entries independently of 12000 performance events; both share monotonic timestamps and sequence numbers. Warn/error still go to sanitized HiLog when capture is off.',
        'App instrumentation is not a native scheduling/GPU stack trace. OS events can arrive late and depend on platform reporting policy.',
        'Ring holds latest 12000 events; summary spans whole capture. Journals rotate at 4 MiB, latest two retained. Capture does not auto-start after process restart.'],
      capture: snapshot, traceEvents: snapshot.events.concat(snapshot.logging.records).sort((a: PerfEvent, b: PerfEvent) => a.seq - b.seq).map((event: PerfEvent): TraceEntry => {
        const args: Record<string, Object> = {};
        Object.keys(event.values).forEach((key: string) => { args[key] = event.values[key]; });
        args.operationId = event.id; args.sequence = event.seq;
        if (event.log) { args.level = event.log.level; args.module = event.log.module; args.event = event.log.event; args.fields = event.log.fields; }
        return { name: event.name, cat: event.name.split('.')[0], ph: event.duration > 0 ? 'X' : 'i', ts: event.time * 1000,
          dur: event.duration > 0 ? event.duration * 1000 : undefined, pid: 1, tid: event.name.startsWith('resource.') ? 2 : 1,
          s: event.duration > 0 ? undefined : 't', args: args };
      }),
      displayTimeUnit: 'ms', journal: await DeveloperDiagnostics.readJournal(false), previousJournal: await DeveloperDiagnostics.readJournal(true) };
    const path = context.cacheDir + '/tinybot-performance.json';
    const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try { await DeveloperDiagnostics.writeAll(file.fd, JSON.stringify(data)); } finally { await fs.close(file); }
    return path;
  }
  static async clear(): Promise<void> {
    DeveloperDiagnostics.stop(); await DeveloperDiagnostics.writing;
    for (const previous of [false, true]) { const path = DeveloperDiagnostics.path(previous); if (await fs.access(path)) { await fs.unlink(path); } }
    DeveloperDiagnostics.journalSession = -1; DeveloperDiagnostics.journalSequence = 0; DeveloperDiagnostics.journalBytes = 0;
    if (DeveloperDiagnostics.context) {
      for (const path of [DeveloperDiagnostics.context.cacheDir + '/tinybot-performance.json', DeveloperDiagnostics.cpuProfilePath()]) {
        if (await fs.access(path)) { await fs.unlink(path); }
      }
    }
    Diagnostics.clear();
    clearRecentDiagnosticLogs();
  }
}
