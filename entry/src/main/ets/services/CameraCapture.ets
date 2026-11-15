import { common } from '@kit.AbilityKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Attachment } from '../model/Productivity';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { Attachments } from './Attachments';
import { IS_PC } from '../common/DeviceForm';

function pcCameraPosition(context: common.UIAbilityContext): camera.CameraPosition {
  if (!canIUse('SystemCapability.Multimedia.Camera.Core')) {
    throw new Error(t('当前设备没有可用的摄像头。'));
  }
  const cameras = camera.getCameraManager(context).getSupportedCameras();
  const selected = cameras.find((item: camera.CameraDevice) => item.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) ??
    cameras.find((item: camera.CameraDevice) => item.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT) ?? cameras[0];
  if (!selected) { throw new Error(t('当前设备没有可用的摄像头。')); }
  return selected.cameraPosition;
}

export async function captureAttachment(context: common.UIAbilityContext): Promise<Attachment[]> {
  const path = context.cacheDir + '/camera-' + util.generateRandomUUID() + '.jpg';
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
  try {
    await fs.close(file);
    const position = IS_PC ? pcCameraPosition(context) : camera.CameraPosition.CAMERA_POSITION_BACK;
    const result = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], {
      cameraPosition: position, saveUri: fileUri.getUriFromPath(path)
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
