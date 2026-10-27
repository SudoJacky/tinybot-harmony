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
  // Protected conversation minimum while a detail pane is docked. The desktop
  // frame protects 400; the tablet composer keeps its tool, usage and effort chips
  // readable a little longer.
  static readonly CHAT_MIN: number = 440;
  static readonly DETAIL_MIN: number = 300;
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
  historyWidth: number;
  chatWidth: number;
  detailWidth: number;
  detailMaxWidth: number;
  detailX: number;

  constructor(width: number, detailOpen: boolean, historyExpanded: boolean = true,
              historyWidth: number = 0, detailWidth: number = 0) {
    this.width = width;
    const workbench = width >= WorkbenchLayout.WORKBENCH_MIN;
    const wanted = Math.max(WorkbenchLayout.HISTORY_MIN, Math.min(WorkbenchLayout.HISTORY_MAX,
      historyWidth > 0 ? historyWidth : WorkbenchLayout.HISTORY_DEFAULT));
    this.docked = workbench && detailOpen;
    // The rail appears exactly when the full column would squeeze the docked pane
    // or the conversation under its minimum; no extra magic breakpoint.
    this.canExpand = workbench && (!this.docked ||
      width - wanted - WorkbenchLayout.CHAT_MIN >= WorkbenchLayout.DETAIL_MIN);
    this.expanded = workbench && historyExpanded && this.canExpand;
    this.rail = workbench && !this.expanded;
    this.historyWidth = !workbench ? 0 : this.expanded ? wanted : WorkbenchLayout.RAIL_WIDTH;
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
