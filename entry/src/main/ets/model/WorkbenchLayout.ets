// All sizes are application-window vp, independent of device type and orientation.
// The workbench follows the desktop frame: the history column collapses to an icon
// rail before either the conversation or the docked detail pane falls below its
// minimum, and both dividers can be dragged inside the same clamp range.
export class WorkbenchLayout {
  static readonly WORKBENCH_MIN: number = 840;
  // Desktop rail geometry: a 36 vp control box between 10 vp side paddings.
  static readonly RAIL_WIDTH: number = 56;
  static readonly HISTORY_MIN: number = 264;
  static readonly HISTORY_MAX: number = 420;
  static readonly HISTORY_DEFAULT: number = 280;
  static readonly PC_WORKBENCH_MIN: number = 720;
  static readonly PC_HISTORY_MIN: number = 224;
  static readonly PC_HISTORY_MAX: number = 360;
  static readonly PC_HISTORY_DEFAULT: number = 252;
  // Protected conversation minimum while a detail pane is docked. The desktop
  // frame protects 400; the tablet composer keeps its tool, usage and effort chips
  // readable a little longer.
  static readonly CHAT_MIN: number = 440;
  static readonly DETAIL_MIN: number = 300;
  static readonly RESIZE_COLLAPSE_OVERSHOOT: number = 32;
  static readonly PC_DOCK_MIN: number = WorkbenchLayout.RAIL_WIDTH + WorkbenchLayout.CHAT_MIN + WorkbenchLayout.DETAIL_MIN;
  static readonly DETAIL_MAX_RATIO: number = 0.7;
  static readonly DETAIL_DEFAULT_RATIO: number = 0.4;
  // The platform caps a custom dialog at 400 vp, which reads as a narrow column in the
  // middle of a tablet. Above the compact width the dialog follows the window instead:
  // 70% of it, clamped so long paragraphs keep a readable line length.
  static readonly DIALOG_MIN_WINDOW: number = 600;
  static readonly DIALOG_WIDTH_RATIO: number = 0.7;
  static readonly DIALOG_MIN: number = 440;
  static readonly DIALOG_MAX: number = 800;

  // Dialog width in vp, or 0 to keep the platform default (phones and split-screen columns).
  static dialogWidth(windowWidth: number): number {
    if (!(windowWidth >= WorkbenchLayout.DIALOG_MIN_WINDOW)) { return 0; }
    return Math.round(Math.min(Math.max(windowWidth * WorkbenchLayout.DIALOG_WIDTH_RATIO,
      WorkbenchLayout.DIALOG_MIN), WorkbenchLayout.DIALOG_MAX));
  }

  width: number;
  docked: boolean;
  // True when the full history column is laid out; false keeps either the rail or,
  // below WORKBENCH_MIN, no persistent history host at all.
  expanded: boolean;
  rail: boolean;
  // Whether the rail may expand in place while keeping the detail pane docked.
  canExpand: boolean;
  historyMinWidth: number;
  historyMaxWidth: number;
  historyWidth: number;
  chatWidth: number;
  detailWidth: number;
  detailMaxWidth: number;
  detailX: number;

  constructor(width: number, detailOpen: boolean, historyExpanded: boolean = true,
              historyWidth: number = 0, detailWidth: number = 0, desktop: boolean = false) {
    this.width = width;
    const workbench = width >= (desktop ? WorkbenchLayout.PC_WORKBENCH_MIN : WorkbenchLayout.WORKBENCH_MIN);
    this.historyMinWidth = desktop ? WorkbenchLayout.PC_HISTORY_MIN : WorkbenchLayout.HISTORY_MIN;
    const historyMax = desktop ? WorkbenchLayout.PC_HISTORY_MAX : WorkbenchLayout.HISTORY_MAX;
    const historyDefault = desktop ? WorkbenchLayout.PC_HISTORY_DEFAULT : WorkbenchLayout.HISTORY_DEFAULT;
    const wanted = Math.max(this.historyMinWidth, Math.min(historyMax, historyWidth > 0 ? historyWidth : historyDefault));
    this.docked = workbench && detailOpen && (!desktop || width >= WorkbenchLayout.PC_DOCK_MIN);
    this.historyMaxWidth = Math.min(historyMax, this.docked ? width - WorkbenchLayout.CHAT_MIN - WorkbenchLayout.DETAIL_MIN
      : desktop ? width - WorkbenchLayout.CHAT_MIN : historyMax);
    // The rail appears exactly when the full column would squeeze the docked pane
    // or the conversation under its minimum; no extra magic breakpoint.
    this.canExpand = workbench && (desktop ? this.historyMinWidth : wanted) <= this.historyMaxWidth;
    this.expanded = workbench && historyExpanded && this.canExpand;
    this.rail = workbench && !this.expanded;
    this.historyWidth = !workbench ? 0 : this.expanded ? Math.min(wanted, this.historyMaxWidth) : WorkbenchLayout.RAIL_WIDTH;
    const available = Math.max(0, width - this.historyWidth - (this.docked ? WorkbenchLayout.CHAT_MIN : 0));
    this.detailMaxWidth = this.docked ? Math.max(WorkbenchLayout.DETAIL_MIN,
      Math.min(width * WorkbenchLayout.DETAIL_MAX_RATIO, available)) : width;
    if (this.docked) {
      const wantedDetail = detailWidth > 0 ? detailWidth : width * WorkbenchLayout.DETAIL_DEFAULT_RATIO;
      this.detailWidth = Math.max(WorkbenchLayout.DETAIL_MIN, Math.min(wantedDetail, this.detailMaxWidth));
      this.detailX = width - this.detailWidth;
      this.chatWidth = Math.max(0, width - this.historyWidth - this.detailWidth);
    } else {
      this.detailWidth = width;
      this.detailX = 0;
      this.chatWidth = Math.max(0, width - this.historyWidth);
    }
  }
}
