import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { outputTokensPerSecond } from '../model/MessageUsage';
import { AgentStepViewModel } from '../viewmodel/SessionViewModels';

@Component
export struct StepUsage {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink step: AgentStepViewModel;
  @Prop identity: string = '';

  private speed(): number | undefined { return outputTokensPerSecond(this.step.usage); }

  build() {
    if (this.speed() !== undefined) {
      Text(t('输出速度') + ' ' + this.speed()!.toFixed(1) + ' tok/s')
        .fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary'))
        .padding({ top: 4, bottom: 4 }).id('step-usage-' + this.identity)
    }
  }
}
