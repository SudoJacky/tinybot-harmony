import { ApplicationStateChangeCallback, common } from '@kit.AbilityKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { answerSpeechChunks, answerSpeechText } from '../model/AnswerSpeechText';
import { t } from '../model/I18n';

@Observed
export class AnswerSpeech {
  messageId: string = '';
  preparing: boolean = false;
  error: string = '';
  private engine?: textToSpeech.TextToSpeechEngine;
  private application?: common.ApplicationContext;
  private generation: number = 0;
  private requestId: string = '';
  private chunks: string[] = [];
  private chunkIndex: number = 0;
  private language: string = 'zh-CN';
  private timer: number = -1;
  // Serialize creation: a cancelled, late engine must be released before another engine is created.
  private static pending: Promise<void> = Promise.resolve();
  private lifecycle: ApplicationStateChangeCallback = {
    onApplicationForeground: (): void => {},
    onApplicationBackground: (): void => {}
  };

  start(context: common.UIAbilityContext, messageId: string, source: string): Promise<void> {
    this.stop();
    if (this.error) { return Promise.resolve(); }
    const generation = this.generation;
    const text = answerSpeechText(source);
    if (!text) { this.error = t('这条回答没有可朗读的正文。'); return Promise.resolve(); }
    if (!canIUse('SystemCapability.AI.TextToSpeech')) {
      this.error = t('此设备不支持系统朗读。'); return Promise.resolve();
    }
    this.messageId = messageId;
    this.preparing = true;
    this.chunks = answerSpeechChunks(text);
    this.chunkIndex = 0;
    this.language = /[\u3400-\u9fff]/.test(text) ? 'zh-CN' : 'en-US';
    try {
      // Capture the observed instance, so a background stop also updates the playback controls.
      this.lifecycle = { onApplicationForeground: (): void => {}, onApplicationBackground: (): void => { this.stop(); } };
      this.application = context.getApplicationContext();
      this.application.on('applicationStateChange', this.lifecycle);
    } catch (error) {
      const detail = error as BusinessError; this.fail(detail.code || 0, detail.message); return Promise.resolve();
    }
    this.deadline(generation);
    AnswerSpeech.pending = AnswerSpeech.pending.then(async () => {
      if (generation !== this.generation) { return; }
      try {
        const engine = await textToSpeech.createEngine({ language: this.language,
          person: this.language === 'zh-CN' ? 0 : 8, online: 1,
          extraParams: { name: 'TinybotAnswer', style: 'interaction-broadcast', locate: 'CN' } });
        if (generation !== this.generation) { engine.shutdown(); return; }
        this.engine = engine;
        engine.setListener({
          onStart: (id: string): void => {
            if (id !== this.requestId) { return; }
            clearTimeout(this.timer); this.preparing = false;
          },
          onComplete: (id: string, response: textToSpeech.CompleteResponse): void => {
            if (id !== this.requestId || response.type !== 1) { return; }
            this.requestId = '';
            this.chunkIndex++;
            if (this.chunkIndex === this.chunks.length) { this.stop(); }
            else { this.speak(generation); }
          },
          onStop: (id: string): void => { if (id === this.requestId) { this.stop(); } },
          onError: (id: string, code: number, message: string): void => {
            if (id === this.requestId) { this.fail(code, message); }
          }
        });
        this.speak(generation);
      } catch (error) {
        const detail = error as BusinessError;
        if (generation === this.generation) { this.fail(detail.code || 0, detail.message); }
        else { hilog.error(0, 'AnswerSpeech', 'Late engine cleanup failed: %{public}s', detail.message); }
      }
    });
    return AnswerSpeech.pending;
  }

  stop(): void {
    this.generation++;
    this.requestId = ''; this.messageId = ''; this.preparing = false; this.error = '';
    clearTimeout(this.timer);
    const engine = this.engine; this.engine = undefined;
    if (this.application) {
      const application = this.application; this.application = undefined;
      try { application.off('applicationStateChange', this.lifecycle); }
      catch (error) { this.reportCleanup(error as BusinessError); }
    }
    if (engine) {
      try { engine.stop(); }
      catch (error) { this.reportCleanup(error as BusinessError); }
      try { engine.shutdown(); }
      catch (error) { this.reportCleanup(error as BusinessError); }
    }
  }

  private speak(generation: number): void {
    if (!this.engine || generation !== this.generation) { return; }
    this.requestId = 'tinybot_' + Date.now() + '_' + generation + '_' + this.chunkIndex;
    this.preparing = true;
    this.deadline(generation);
    try {
      this.engine.speak(this.chunks[this.chunkIndex], { requestId: this.requestId,
        extraParams: { languageContext: this.language, playType: 1, soundChannel: 1, speed: 1 } });
      hilog.info(0, 'AnswerSpeech', 'Playback requested chunk=%{public}d/%{public}d', this.chunkIndex + 1, this.chunks.length);
    } catch (error) { const detail = error as BusinessError; this.fail(detail.code || 0, detail.message); }
  }

  private deadline(generation: number): void {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      if (generation === this.generation) { this.stop(); this.error = t('系统朗读响应超时，请重试。'); }
    }, 15000);
  }

  private fail(code: number, message: string): void {
    hilog.error(0, 'AnswerSpeech', 'Playback failed code=%{public}d message=%{public}s', code, message);
    this.stop();
    this.error = t('朗读失败（{0}）：{1}', [code, message]);
  }

  private reportCleanup(error: BusinessError): void {
    hilog.error(0, 'AnswerSpeech', 'Cleanup failed code=%{public}d message=%{public}s', error.code || 0, error.message);
    this.error = t('停止朗读失败：{0}', [error.message]);
  }
}
