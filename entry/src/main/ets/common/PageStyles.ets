import { AdaptiveUi } from '../model/AdaptiveUi';

class ContentStyle implements AttributeModifier<CommonAttribute> {
  private maximum: number;
  constructor(maximum: number) { this.maximum = maximum; }
  applyNormalAttribute(instance: CommonAttribute): void {
    instance.width('100%').constraintSize({ maxWidth: this.maximum });
  }
}

export class PageStyles {
  static readonly form: AttributeModifier<CommonAttribute> = new ContentStyle(AdaptiveUi.formWidth);
  static readonly reading: AttributeModifier<CommonAttribute> = new ContentStyle(AdaptiveUi.readingWidth);
  static readonly choices: AttributeModifier<CommonAttribute> = new ContentStyle(AdaptiveUi.choiceWidth);
}
