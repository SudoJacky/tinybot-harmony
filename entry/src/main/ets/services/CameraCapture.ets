import { common } from '@kit.AbilityKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Attachment } from '../model/Productivity';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { Attachments } from './Attachments';

export async function captureAttachment(context: common.UIAbilityContext): Promise<Attachment[]> {
  const path = context.cacheDir + '/camera-' + util.generateRandomUUID() + '.jpg';
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
  try {
    await fs.close(file);
    const result = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], {
      cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK, saveUri: fileUri.getUriFromPath(path)
    });
    // The picker also returns -1 when the user leaves without confirming a photo.
    if (result.resultCode === -1) {
      Diagnostics.log('info', 'camera', 'dismissed', { code: result.resultCode });
      return [];
    }
    if (result.resultCode !== 0 || !result.resultUri || result.mediaType !== cameraPicker.PickerMediaType.PHOTO) {
      throw new Error(t('相机未返回有效照片（{0}）。', [result.resultCode]));
    }
    const attachment = await Attachments.import(result.resultUri, true);
    Diagnostics.log('info', 'camera', 'imported', { bytes: attachment.size });
    return [attachment];
  } catch (error) {
    Diagnostics.log('error', 'camera', 'capture_failed', undefined, error as Error);
    throw error as Error;
  } finally {
    await fs.unlink(path);
  }
}
