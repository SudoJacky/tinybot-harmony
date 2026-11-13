import { deviceInfo } from '@kit.BasicServicesKit';

export const IS_PC: boolean = deviceInfo.deviceType === '2in1';
