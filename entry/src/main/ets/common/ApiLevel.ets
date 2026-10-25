import { deviceInfo } from '@kit.BasicServicesKit';

// One place to decide whether an API-26-only capability exists on the running system.
// deviceInfo.sdkApiVersion exists since API 6, so it is safe on every supported version;
// deviceInfo.apiAvailable() (API 26) must not be the first check for exactly that reason.
//
// Each flag describes a concrete capability, not a build setting:
//  - material: immersive material namespace, ImmersiveMaterial, Material.empty, systemMaterial
//    and getGlobalMaterialLevel() all ship with @ohos.arkui.uiMaterial in API 26. Older systems
//    have no such native module, so reading any of those values throws.
//  - redirectLimit: http.HttpRequestOptions.maxRedirects and the interceptor types are API 23+.
//  - pdfTextContent: pdfService.PdfPage.getTextContent() ships with 6.1.0(23).
//  - drawingTools: HiddenToolType / hiddenTools.hiddenOptionalTools ships with API 26.
export class ApiLevel {
  static readonly sdk: number = deviceInfo.sdkApiVersion;
  static readonly material: boolean = ApiLevel.sdk >= 26;
  static readonly redirectLimit: boolean = ApiLevel.sdk >= 23;
  static readonly pdfTextContent: boolean = ApiLevel.sdk >= 23;
  static readonly drawingTools: boolean = ApiLevel.sdk >= 26;
}
