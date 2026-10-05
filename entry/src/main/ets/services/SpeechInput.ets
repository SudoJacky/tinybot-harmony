import { abilityAccessCtrl, ApplicationStateChangeCallback, common } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t } from '../model/I18n';

export type SpeechPhase = 'idle' | 'preparing' | 'listening' | 'finishing' | 'complete' | 'error';

// The system owns audio capture. The consumer receives full transcript updates.
@Observed
export class SpeechInput {
  phase: SpeechPhase = 'idle';
  text: string = '';
  error: string = '';
  permissionDenied: boolean = false;
  startedAt: number = 0;
  speaking: boolean = false;
  onResult: (text: string) => void = () => {};
  onError: () => void = () => {};
  onComplete: () => void = () => {};
  onBackground: () => void = () => {};
  private engine?: speechRecognizer.SpeechRecognitionEngine;
  private application?: common.ApplicationContext;
  private sessionId: string = '';
  private sequence: number = 0;
  private confirmed: string = '';
  private timer: number = -1;
  private lifecycle: ApplicationStateChangeCallback = {
    onApplicationForeground: (): void => {},
    onApplicationBackground: (): void => { this.cancel(); this.onBackground(); }
  };

  async start(context: common.UIAbilityContext, openPermissionSetting: boolean = false): Promise<void> {
    this.cancel();
    const id = 'tinybot_' + Date.now() + '_' + (++this.sequence);
    this.sessionId = id;
    this.phase = 'preparing';
    try {
      if (!canIUse('SystemCapability.AI.SpeechRecognizer')) {
        throw new Error(t('此设备不支持系统语音识别。'));
      }
      this.application = context.getApplicationContext();
      this.application.on('applicationStateChange', this.lifecycle);
      const permissions = abilityAccessCtrl.createAtManager();
      let granted = (await permissions.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE'])).authResults[0];
      if (this.sessionId !== id) { return; }
      // Only a separate, explicit tap may open settings after a denial.
      if (granted !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED && openPermissionSetting) {
        granted = (await permissions.requestPermissionOnSetting(context, ['ohos.permission.MICROPHONE']))[0];
        if (this.sessionId !== id) { return; }
      }
      if (granted !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.permissionDenied = true;
        throw new Error(t('未获得麦克风权限，请在系统设置中允许 Tinybot 使用麦克风。'));
      }
      this.deadline(id, 15000);
      const engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1,
        extraParams: { recognizerMode: 'long' } });
      // Permission and engine creation may finish after the sheet has been dismissed.
      if (this.sessionId !== id) { engine.shutdown(); return; }
      this.engine = engine;
      engine.setListener({
        onStart: (sessionId: string): void => {
          if (this.sessionId !== sessionId || this.phase !== 'preparing') { return; }
          clearTimeout(this.timer);
          this.startedAt = Date.now();
          this.phase = 'listening';
          // The engine also enforces this duration; the timer stops capture if completion is delayed.
          this.timer = setTimeout(() => this.finish(), 10 * 60 * 1000);
        },
        onEvent: (sessionId: string, eventCode: number): void => {
          if (this.sessionId === sessionId && (eventCode === 1 || eventCode === 3)) {
            this.speaking = eventCode === 1;
          }
        },
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          if (this.sessionId !== sessionId) { return; }
          // Partial results replace the current clause, while final clauses accumulate.
          this.text = this.confirmed + result.result;
          if (result.isFinal || result.isLast) { this.confirmed = this.text; }
          this.onResult(this.text);
        },
        onComplete: (sessionId: string): void => {
          if (this.sessionId !== sessionId) { return; }
          this.release(false);
          this.phase = 'complete';
          this.onComplete();
        },
        onError: (sessionId: string, code: number): void => {
          if (this.sessionId === sessionId) { this.fail(this.errorMessage(code)); }
        }
      });
      engine.startListening({ sessionId: id,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
        extraParams: { recognitionMode: 0, maxAudioDuration: 10 * 60 * 1000 } });
    } catch (error) {
      if (this.sessionId === id) {
        const detail = error as BusinessError;
        this.fail(detail.code ? this.errorMessage(detail.code) : detail.message);
      }
    }
  }

  finish(): void {
    if (this.phase !== 'listening' || !this.engine) { return; }
    this.phase = 'finishing';
    this.deadline(this.sessionId, 10000);
    try { this.engine.finish(this.sessionId); }
    catch (error) { this.fail(this.errorMessage((error as BusinessError).code)); }
  }

  cancel(): void {
    this.release(true);
    this.phase = 'idle';
    this.text = '';
    this.confirmed = '';
    this.error = '';
    this.permissionDenied = false;
    this.startedAt = 0;
  }

  private deadline(id: string, delay: number): void {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      if (this.sessionId === id) { this.fail(t('系统语音识别响应超时，请重试。')); }
    }, delay);
  }

  private fail(message: string): void {
    this.release(true);
    this.error = message;
    this.phase = 'error';
    this.onError();
  }

  private errorMessage(code: number): string {
    if (code === 1002200012 || code === 201) {
      return t('未获得麦克风权限，请在系统设置中允许 Tinybot 使用麦克风。');
    }
    return t('系统语音识别失败（{0}），请确认设备支持此功能后重试。', [String(code)]);
  }

  private release(cancel: boolean): void {
    clearTimeout(this.timer);
    this.speaking = false;
    const id = this.sessionId;
    this.sessionId = '';
    const engine = this.engine;
    this.engine = undefined;
    if (engine) {
      try { if (cancel) { engine.cancel(id); } }
      catch (error) { hilog.warn(0, 'SpeechInput', 'Cancel failed: %{public}d', (error as BusinessError).code); }
      finally { engine.shutdown(); }
    }
    if (this.application) {
      this.application.off('applicationStateChange', this.lifecycle);
      this.application = undefined;
    }
  }
}
