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
  // The system owns the rating and comment form; this promise does not report a submitted review.
  await commentManager.showCommentDialog(context);
}
