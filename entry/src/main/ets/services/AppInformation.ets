import { bundleManager, common } from '@kit.AbilityKit';

export interface AppInformation {
  bundleName: string;
  versionName: string;
  versionCode: number;
}

// Read the installed package so the About page follows the actual build.
export function readAppInformation(): AppInformation {
  const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
  return { bundleName: info.name, versionName: info.versionName, versionCode: info.versionCode };
}

export async function requestAppReview(context: common.UIAbilityContext): Promise<void> {
  // An explicit user action opens the store's review page instead of a rate-limited prompt.
  // Starting the page does not mean the user submitted a review.
  const info = readAppInformation();
  await context.startAbility({
    action: 'ohos.want.action.appdetail',
    uri: 'store://appgallery.huawei.com/app/detail?id=' + encodeURIComponent(info.bundleName) + '&action=write-review'
  });
}
