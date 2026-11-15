import { deviceInfo } from '@kit.BasicServicesKit';

export const IS_PC: boolean = deviceInfo.deviceType === '2in1';
export const IS_LARGE_SCREEN: boolean = IS_PC || deviceInfo.deviceType === 'tablet';
