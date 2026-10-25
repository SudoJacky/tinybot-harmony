// All sizes are application-window vp, independent of device type and orientation.
export class WorkbenchLayout {
  width: number;
  historyWidth: number;
  detailWidth: number;
  detailX: number;
  docked: boolean;
  constructor(width: number, detailOpen: boolean) {
    this.width = width;
    this.docked = detailOpen && width >= 840;
    this.historyWidth = width >= 840 && (!detailOpen || width >= 1200) ? 280 : 0;
    this.detailWidth = this.docked ? Math.max(360, Math.min(480, width * 0.38, width - this.historyWidth - 480)) : width;
    this.detailX = this.docked ? width - this.detailWidth : 0;
  }
}
