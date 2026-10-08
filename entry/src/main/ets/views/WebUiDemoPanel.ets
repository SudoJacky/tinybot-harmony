import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { InteractiveAnswer } from './InteractiveAnswer';
import { UiValues, parseUiSurface, validateUiState, copyUiValues } from '../model/InteractiveUi';
import { t } from '../model/I18n';
import { Btn } from '../common/Theme';
interface WebUiExample { content: string; }
@Component
export struct WebUiDemoPanel {
  @State private examples: string[] = [];
  @State private selected: number = 0;
  @State private error: string = '';
  aboutToAppear(): void { this.load(); }
  private async load(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const examples: string[] = [];
      for (const file of ['example.json', 'example-2d.json']) {
        const bytes = await context.resourceManager.getRawFileContent('interactive-web/' + file);
        examples.push((JSON.parse(new util.TextDecoder('utf-8').decodeToString(bytes)) as WebUiExample).content);
      }
      this.examples = examples;
    } catch (error) { this.error = (error as Error).message; }
  }
  private async interact(index: number, key: string, values: UiValues, action: string): Promise<UiValues> {
    const document = parseUiSurface(this.examples[index], key.split(':')[1]);
    if (action && action !== 'reset') { throw new Error('Unsupported demo action'); }
    const next = action === 'reset' ? document.initial : values;
    validateUiState(document, next); return copyUiValues(next);
  }
  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Button(t('三维场景')).attributeModifier(Btn.textSmall).onClick(() => { this.selected = 0; })
          Button(t('二维动画')).attributeModifier(Btn.textSmall).onClick(() => { this.selected = 1; })
        }
        if (this.error) { Text(this.error).fontColor($r('app.color.danger')) }
        if (this.examples.length === 2) {
          ForEach([this.selected], (index: number) => {
            InteractiveAnswer({ content: this.examples[index], available: true,
              onInteract: (key: string, values: UiValues, action: string) => this.interact(index, key, values, action) })
          }, (index: number) => String(index))
        }
      }.padding(16).width('100%')
    }.height('100%').width('100%').align(Alignment.Top)
  }
}
