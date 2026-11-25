import { KeyCode } from '@kit.InputKit';
import { AppearanceStyle } from './AppearanceStyle';
import { Motion } from './Theme';
import { IconButton } from './Widgets';
import { t } from '../model/I18n';

@Component
export struct SearchPill {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop open: boolean = false;
  @Prop opensLeft: boolean = false;
  @Prop disabled: boolean = false;
  @Prop diameter: number = 44;
  @Prop expandedWidth: number = 44;
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop maxLength: number = Infinity;
  @Prop pillId: string = '';
  @Prop toggleId: string = '';
  @Prop inputId: string = '';
  @Prop closeId: string = '';
  onOpen: () => void = () => {};
  onClose: () => void = () => {};
  onChange: (value: string) => void = () => {};
  onInputVisible: () => void = () => {};

  @Builder
  launcher() {
    Stack() {
      SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(19)
        .fontColor([$r('app.color.text_secondary')]).accessibilityLevel('no')
      if (!this.open) {
        Button({ type: ButtonType.Circle }).id(this.toggleId).width(this.diameter).height(this.diameter)
          .backgroundColor(Color.Transparent).accessibilityText(this.label).enabled(!this.disabled).onClick(this.onOpen)
      }
    }.width(this.diameter).height(this.diameter).flexShrink(0)
  }

  build() {
    Flex({ direction: this.opensLeft ? FlexDirection.RowReverse : FlexDirection.Row, alignItems: ItemAlign.Center }) {
      this.launcher()
      if (this.open) {
        TextInput({ text: this.value, placeholder: this.label })
          .id(this.inputId).layoutWeight(1).height(this.diameter).padding(0)
          .fontFamily(this.appearance.fontFamily).fontSize(15).placeholderColor($r('app.color.text_tertiary'))
          .backgroundColor(Color.Transparent).enabled(!this.disabled).accessibilityText(this.label).maxLength(this.maxLength)
          .enterKeyType(EnterKeyType.Search).onSubmit(() => this.getUIContext().getFocusController().clearFocus())
          .onChange(this.onChange)
          .onVisibleAreaChange([0], (visible: boolean) => { if (visible) { this.onInputVisible(); } })
          .onKeyEvent((event: KeyEvent) => {
            if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
              this.onClose();
              event.stopPropagation();
            }
          })
        IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭搜索'), compId: this.closeId,
          diameter: this.diameter, iconSize: 15, onTap: this.onClose })
      }
    }.id(this.pillId).width(this.open ? this.expandedWidth : this.diameter).height(this.diameter)
      .borderRadius(this.diameter / 2).clip(true).backgroundColor($r('app.color.surface_variant'))
      .animation({ duration: this.appearance.effectStrength > 0 ? Motion.fast : 0, curve: Motion.standard })
  }
}
