import { bundleManager, common } from '@kit.AbilityKit';
import { commentManager } from '@kit.AppGalleryKit';

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
  // The API does not report whether a review was submitted. Never record it as a rating.
  await commentManager.showCommentDialog(context);
}
