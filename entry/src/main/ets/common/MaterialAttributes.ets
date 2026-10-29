import { uiMaterial } from '@kit.ArkUI';

// `systemMaterial` is a CommonMethod member that only exists from API 26. Calling it on an older
// system raises a TypeError, and passing undefined does not help because the method itself is
// missing. An AttributeModifier keeps the call out of the chain: on API 20 the modifier is a no-op,
// on API 26 it applies exactly the material the inline call used to apply.
class MaterialAttribute<T extends CommonAttribute> implements AttributeModifier<T> {
  private material?: uiMaterial.Material;

  constructor(material?: uiMaterial.Material) { this.material = material; }

  applyNormalAttribute(instance: T): void {
    const material = this.material;
    if (!material) { return; }
    instance.systemMaterial(material);
  }
}

export function systemMaterialAttribute<T extends CommonAttribute>(material?: uiMaterial.Material): AttributeModifier<T> {
  return new MaterialAttribute<T>(material);
}

// Select keeps a second, menu-only material slot with its own API-26 method.
class MenuMaterialAttribute implements AttributeModifier<SelectAttribute> {
  private material?: uiMaterial.Material;

  constructor(material?: uiMaterial.Material) { this.material = material; }

  applyNormalAttribute(instance: SelectAttribute): void {
    // Select's option labels have their own colors, independent of the trigger's fontColor.
    instance.optionFontColor($r('sys.color.font_primary'));
    instance.selectedOptionFontColor($r('sys.color.font_primary'));
    instance.selectedOptionBgColor($r('sys.color.comp_background_tertiary'));
    const material = this.material;
    if (!material) { return; }
    instance.menuSystemMaterial(material);
  }
}

export function menuMaterialAttribute(material?: uiMaterial.Material): AttributeModifier<SelectAttribute> {
  return new MenuMaterialAttribute(material);
}
