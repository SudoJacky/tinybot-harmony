import { t, getLocale } from '../model/I18n';
import { RequestUsage, UsageOrigin, UsageToolActivity } from '../model/Usage';
import { UsageActivity, UsageDay, UsageGroup, UsageModel, UsagePeriod, UsageSession, UsageStatistics, UsageFilter, reportedTokens } from '../model/UsageStatistics';
import { UsageCursor, UsageQuery } from '../model/UsageQuery';
import { UsageLedger } from '../services/UsageLedger';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Space, compactNumber } from '../common/Theme';
import { Banner, EmptyState, GroupCard, NavRow, RowDivider, SectionHeader, Segmented, StatTile, Tag } from '../common/Widgets';

@Component
export struct UsagePanel {
  @ObjectLink app: ChatViewModel;
  @State private range: number = 2;
  @State private provider: string = '';
  @State private model: string = '';
  private providers: string[] = [];
  private models: string[] = [];
  @State private threadFilter: string = '';
  private sessionOptions: UsageSession[] = [];
  @State private tab: number = 0;
  @State private expandedSession: string = '';
  @State private expandedTurn: string = '';
  @State private expandedWeek: string = '';
  @State private sessionPage: number = 0;
  @State private turnPage: number = 0;
  @State private turnRequestPage: number = 0;
  @State private weekPage: number = 0;
  @State private toolPage: number = 0;
  @State private skillPage: number = 0;
  @State private detailToolPage: number = 0;
  @State private stats: UsageStatistics = new UsageStatistics();
  @State private error: string = '';
  @State private requestPage: number = 0;
  @State private modelPage: number = 0;
  @State private expanded: string = '';
  @State private day: string = '';
  @State private showFilter: boolean = false;
  @State private filterKind: string = 'provider';
  private unsubscribe?: () => void;

  @State private loading: boolean = true;
  @State private pageLoading: boolean = false;
  @State private revisionKey: number = 0;
  @State private requestRows: RequestUsage[] = [];
  @State private turnRows: UsageGroup[] = [];
  @State private turnRequests: RequestUsage[] = [];
  @State private requestHasNext: boolean = false;
  @State private turnHasNext: boolean = false;
  @State private sessionCount: number = 0;
  @State private turnCount: number = 0;
  @State private weekCount: number = 0;
  @State private modelCount: number = 0;
  @State private toolCount: number = 0;
  @State private skillCount: number = 0;
  @State private filterPage: number = 0;
  @State private filterItems: string[] = [];
  @State private filterCount: number = 0;
  private filterAll: string[] = [];
  private fullStats: UsageStatistics = new UsageStatistics();
  private fullTurns: UsageGroup[] = [];
  private turnCacheKey: string = '';
  private query?: UsageQuery;
  private queryRevision: number = -1;
  private generation: number = 0;
  private detailGeneration: number = 0;
  private refreshTimer: number = -1;
  private mounted: boolean = false;
  private legacyResolved: boolean = false;
  private legacy: Map<string, UsageOrigin> = new Map();
  private pendingRefresh: boolean = false;
  private requestCursors: (UsageCursor | undefined)[] = [undefined];
  private turnCursors: (UsageCursor | undefined)[] = [undefined];
  private requestNext?: UsageCursor;
  private turnNext?: UsageCursor;
  private currentFilter: UsageFilter = { range: 2, provider: '', model: '', threadId: '', now: Date.now() };

  aboutToAppear(): void {
    this.mounted = true; this.refresh();
    this.unsubscribe = UsageLedger.subscribe(() => {
      this.error = UsageLedger.error;
      if (this.refreshTimer < 0 && this.queryRevision !== UsageLedger.revision) {
        this.refreshTimer = setTimeout(() => {
          this.refreshTimer = -1;
          if (this.loading) { this.pendingRefresh = true; } else { this.refresh(); }
        }, 300);
      }
    });
  }
  aboutToDisappear(): void {
    this.mounted = false; this.generation++; this.detailGeneration++;
    this.unsubscribe?.(); clearTimeout(this.refreshTimer); this.query?.cancel();
  }
  private async refresh(): Promise<void> {
    const generation = ++this.generation; this.detailGeneration++; this.query?.cancel(); this.loading = true; this.pageLoading = false;
    const revision = UsageLedger.revision;
    let records = UsageLedger.list();
    if (!this.legacyResolved && UsageLedger.isReady) {
      const originals = records;
      records = this.app.attributeUsage(records);
      for (let index = 0; index < records.length; index++) {
        if (records[index] !== originals[index] && records[index].origin) { this.legacy.set(records[index].id, records[index].origin!); }
      }
      this.legacyResolved = true;
    } else if (this.legacy.size > 0) {
      records = records.map((item: RequestUsage): RequestUsage => {
        const previous = this.legacy.get(item.id);
        if (!item.origin?.threadId && previous) {
          const copy: RequestUsage = { id: item.id, provider: item.provider, model: item.model, startedAt: item.startedAt,
            durationMs: item.durationMs, status: item.status, firstTokenMs: item.firstTokenMs, tokens: item.tokens, tools: item.tools, origin: previous };
          return copy;
        }
        return item;
      });
    }
    const query = new UsageQuery(records); this.query = query;
    const filter: UsageFilter = { range: this.range, provider: this.provider, model: this.model, threadId: this.threadFilter, now: Date.now() };
    this.currentFilter = filter;
    try {
      const options = await query.options(this.provider);
      const summary = await query.summary(filter);
      if (!this.mounted || generation !== this.generation) { return; }
      this.providers = options.providers; this.models = options.models; this.sessionOptions = options.sessions;
      this.fullStats = summary; this.queryRevision = revision; this.turnCacheKey = ''; this.applyPages();
      this.error = UsageLedger.error; this.loading = false; await this.loadDetails();
    } catch (error) { if (this.mounted && generation === this.generation) { this.error = (error as Error).message; this.loading = false; } }
    finally {
      if (this.mounted && generation === this.generation && this.pendingRefresh) {
        this.pendingRefresh = false;
        if (this.refreshTimer < 0) { this.refreshTimer = setTimeout(() => { this.refreshTimer = -1; this.refresh(); }, 300); }
      }
    }
  }
  private applyPages(): void {
    const full = this.fullStats; const view = new UsageStatistics();
    this.sessionCount = full.sessions.length; this.weekCount = full.weeks.length; this.modelCount = full.models.length;
    this.toolCount = full.tools.length; this.skillCount = full.skills.length;
    this.sessionPage = Math.min(this.sessionPage, Math.max(0, Math.ceil(this.sessionCount / 10) - 1));
    this.weekPage = Math.min(this.weekPage, Math.max(0, Math.ceil(this.weekCount / 8) - 1));
    this.modelPage = Math.min(this.modelPage, Math.max(0, Math.ceil(this.modelCount / 5) - 1));
    this.toolPage = Math.min(this.toolPage, Math.max(0, Math.ceil(this.toolCount / 10) - 1));
    this.skillPage = Math.min(this.skillPage, Math.max(0, Math.ceil(this.skillCount / 10) - 1));
    view.totals = full.totals; view.days = full.days; view.peak = full.peak; view.purposes = full.purposes;
    view.sessions = full.sessions.slice(this.sessionPage * 10, this.sessionPage * 10 + 10);
    view.weeks = full.weeks.slice(this.weekPage * 8, this.weekPage * 8 + 8);
    view.models = full.models.slice(this.modelPage * 5, this.modelPage * 5 + 5);
    view.tools = full.tools.slice(this.toolPage * 10, this.toolPage * 10 + 10);
    view.skills = full.skills.slice(this.skillPage * 10, this.skillPage * 10 + 10);
    this.stats = view; this.revisionKey++;
  }
  private async loadDetails(): Promise<void> {
    const query = this.query; if (!query || this.loading) { return; }
    const generation = ++this.detailGeneration; this.pageLoading = true;
    try {
      if (this.tab === 1 && this.expandedSession) {
        if (this.turnCacheKey !== this.expandedSession) {
          const turns = await query.turns(this.currentFilter, this.expandedSession, () => this.mounted && generation === this.detailGeneration);
          if (!this.mounted || query !== this.query || generation !== this.detailGeneration) { return; }
          this.fullTurns = turns; this.turnCacheKey = this.expandedSession;
        }
        this.turnCount = this.fullTurns.length;
        this.turnPage = Math.min(this.turnPage, Math.max(0, Math.ceil(this.turnCount / 10) - 1));
        this.turnRows = this.fullTurns.slice(this.turnPage * 10, this.turnPage * 10 + 10);
      }
      if (this.tab === 3 || (this.tab === 1 && this.expandedTurn)) {
        const requests = this.tab === 3;
        const page = await query.page(this.currentFilter, requests ? this.requestCursors[this.requestPage] : this.turnCursors[this.turnRequestPage],
          requests ? '' : this.expandedSession, requests ? '' : this.expandedTurn, () => this.mounted && generation === this.detailGeneration);
        if (!this.mounted || query !== this.query || generation !== this.detailGeneration) { return; }
        if (requests) { this.requestRows = page.records; this.requestNext = page.next; this.requestHasNext = !!page.next; }
        else { this.turnRequests = page.records; this.turnNext = page.next; this.turnHasNext = !!page.next; }
      }
      this.revisionKey++;
    } catch (error) { if (this.mounted && query === this.query && generation === this.detailGeneration) { this.error = (error as Error).message; } }
    finally { if (this.mounted && generation === this.detailGeneration) { this.pageLoading = false; } }
  }
  private moveRequests(next: boolean, turn: boolean): void {
    if (this.pageLoading || this.loading) { return; }
    this.expanded = '';
    if (turn) {
      if (next) { this.turnCursors[this.turnRequestPage + 1] = this.turnNext; this.turnRequestPage++; } else { this.turnRequestPage--; }
    } else {
      if (next) { this.requestCursors[this.requestPage + 1] = this.requestNext; this.requestPage++; } else { this.requestPage--; }
    }
    this.loadDetails();
  }
  private filter(): void {
    this.requestPage = 0; this.modelPage = 0; this.day = ''; this.expanded = '';
    this.expandedSession = ''; this.expandedTurn = ''; this.expandedWeek = ''; this.sessionPage = 0; this.weekPage = 0; this.toolPage = 0; this.skillPage = 0;
    this.requestCursors = [undefined]; this.turnCursors = [undefined]; this.requestRows = []; this.turnRows = []; this.turnRequests = [];
    this.stats = new UsageStatistics(); this.fullStats = this.stats;
    this.refresh();
  }
  private moveFilter(page: number): void { this.filterPage = page; this.filterItems = this.filterAll.slice(page * 50, page * 50 + 50); }
  private providerName(id: string): string { return this.app.providerProfiles.find((item) => item.id === id)?.name || id; }
  private filterOptions(): string[] {
    return [''].concat(this.filterKind === 'provider' ? this.providers : this.filterKind === 'model' ? this.models : this.sessionOptions.map((item) => item.key));
  }
  private sessionName(id: string): string {
    if (id === 'unassigned') { return t('未归属'); }
    return this.app.threads.find((item) => item.id === id)?.displayTitle || this.sessionOptions.find((item) => item.key === id)?.label || t('已删除会话');
  }
  private filterTitle(): string { return this.filterKind === 'provider' ? t('服务') : this.filterKind === 'model' ? t('模型') : t('会话'); }
  private optionName(id: string): string {
    if (this.filterKind === 'provider') { return id ? this.providerName(id) : t('全部服务'); }
    if (this.filterKind === 'model') { return id || t('全部模型'); }
    return id ? this.sessionName(id) : t('全部会话');
  }
  private selectedFilter(): string { return this.filterKind === 'provider' ? this.provider : this.filterKind === 'model' ? this.model : this.threadFilter; }
  private openFilter(kind: string): void {
    this.filterKind = kind; this.filterAll = this.filterOptions(); this.filterCount = this.filterAll.length; this.moveFilter(0);
    this.showFilter = true;
  }
  private chooseFilter(id: string): void {
    if (this.filterKind === 'provider') { this.provider = id; this.model = ''; }
    else if (this.filterKind === 'model') { this.model = id; }
    else { this.threadFilter = id; }
    this.showFilter = false;
    this.filter();
  }
  private number(value: number): string { return value.toLocaleString(getLocale()); }
  private count(value: number | undefined): string { return value === undefined ? t('未报告') : this.number(value); }
  private total(value: number): string { return this.stats.totals.calls > 0 && this.stats.totals.reported === 0 ? '—' : this.number(value); }
  private selectedDay(): UsageDay { return this.stats.days.find((item: UsageDay) => item.date === this.day) || this.stats.days[this.stats.days.length - 1] || new UsageDay(); }
  private status(item: RequestUsage): string {
    if (item.status === 'complete') { return t('完成'); }
    if (item.status === 'failed') { return t('失败'); }
    if (item.status === 'cancelled') { return t('已取消'); }
    return t('进行中 / 结果不确定');
  }

  @Builder
  filterSheet() {
    Scroll() {
      Column() {
        GroupCard() {
          Column() {
            ForEach(this.filterItems, (id: string, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: this.optionName(id), trailing: 'select', active: id === this.selectedFilter(),
                compId: 'usage-filter-option-' + (this.filterPage * 50 + index), onTap: () => this.chooseFilter(id) })
            }, (id: string) => this.filterKind + ':' + id)
          }
        }
        if (this.filterCount > 50) { this.pager(this.filterPage, (this.filterPage + 1) * 50 < this.filterCount, () => this.moveFilter(this.filterPage - 1), () => this.moveFilter(this.filterPage + 1)) }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
    }.width('100%').height(Math.min(440, (this.filterItems.length + (this.filterCount > 50 ? 1 : 0)) * 57 + Space.sm + Space.xl))
      .align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  filters() {
    Column({ space: Space.md }) {
      Segmented({ options: [t('今天'), t('近 7 天'), t('近 30 天'), t('全部')], selected: this.range, compIdPrefix: 'usage-range',
        onSelect: (index: number) => { this.range = index; this.filter(); } })
      GroupCard() {
        Column() {
          NavRow({ title: t('服务'), subtitle: this.provider ? this.providerName(this.provider) : t('全部服务'), compId: 'usage-provider',
            onTap: () => this.openFilter('provider') })
          RowDivider()
          NavRow({ title: t('模型'), subtitle: this.model || t('全部模型'), compId: 'usage-model',
            onTap: () => this.openFilter('model') })
          RowDivider()
          NavRow({ title: t('会话'), subtitle: this.threadFilter ? this.sessionName(this.threadFilter) : t('全部会话'), compId: 'usage-thread',
            onTap: () => this.openFilter('thread') })
        }
      }
    }.width('100%').padding({ top: Space.sm })
  }

  @Builder
  metric(label: string, value: string) {
    Row({ space: Space.sm }) {
      Text(label).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      Text(value).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
    }.width('100%')
  }

  @Builder
  overview() {
    SectionHeader({ title: t('用量概览') })
    GroupCard() {
      Column({ space: Space.md }) {
        Text(t('总 Token')).fontSize(13).fontColor($r('app.color.text_secondary'))
        Text(this.total(this.stats.totals.total)).id('usage-total').fontSize(34).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent')).maxLines(1).minFontSize(20).maxFontSize(34)
        Row({ space: Space.sm }) {
          StatTile({ value: this.total(this.stats.totals.input), label: t('输入 Token') })
          StatTile({ value: this.total(this.stats.totals.output), label: t('输出 Token') })
        }.width('100%')
        this.metric(t('缓存读取（输入内）'), this.count(this.stats.totals.cachedReports ? this.stats.totals.cached : undefined))
        this.metric(t('缓存写入（输入内）'), this.count(this.stats.totals.cacheWriteReports ? this.stats.totals.cacheWrite : undefined))
        this.metric(t('推理（输出内）'), this.count(this.stats.totals.reasoningReports ? this.stats.totals.reasoning : undefined))
      }.width('100%').alignItems(HorizontalAlign.Start).padding(Space.lg)
    }
    Row({ space: Space.sm }) {
      StatTile({ value: this.number(this.stats.totals.calls), label: t('请求') })
      StatTile({ value: this.number(this.stats.totals.reported), label: t('已报告用量') })
      StatTile({ value: this.number(this.stats.totals.missing), label: t('未报告') })
    }.width('100%').margin({ top: Space.sm })
    Text(t('失败 {0} · 已取消 {1} · 进行中 / 结果不确定 {2}', [this.stats.totals.failed, this.stats.totals.cancelled, this.stats.totals.pending]))
      .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%').margin({ top: Space.sm })
  }

  @Builder
  trend() {
    SectionHeader({ title: t('每日趋势') })
    GroupCard() {
      Column({ space: Space.sm }) {
        Text(compactNumber(Math.max(0, ...this.stats.days.map((item: UsageDay) => item.total))) + ' Token')
          .fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).width('100%')
        Row({ space: this.stats.days.length > 7 ? 3 : 8 }) {
          ForEach(this.stats.days, (item: UsageDay) => {
            Column() {
              Column().width('100%').height(item.total > 0 ? Math.max(3, item.total / this.stats.peak * 100) : 2)
                .backgroundColor(item.date === this.selectedDay().date ? $r('app.color.accent') : $r('app.color.text_tertiary')).borderRadius(3)
            }.layoutWeight(1).height(110).justifyContent(FlexAlign.End)
              .id('usage-day-' + item.date).accessibilityText(item.date + ' · ' + (item.calls > 0 && item.reported === 0 ? t('未报告') : this.number(item.total) + ' Token'))
              .onClick(() => { this.day = item.date; })
          }, (item: UsageDay) => JSON.stringify(item))
        }.width('100%')
        Row() {
          Text(this.stats.days[0]?.date.slice(5) || '')
            .fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
          Blank()
          Text(this.stats.days[this.stats.days.length - 1]?.date.slice(5) || '')
            .fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
        }.width('100%')
        Text(this.selectedDay().date + ' · ' + (this.selectedDay().calls > 0 && this.selectedDay().reported === 0 ? t('未报告') : this.number(this.selectedDay().total) + ' Token'))
          .fontSize(14).fontColor($r('app.color.text_primary')).width('100%')
        Text(t('{0} 次请求 · {1} 次未报告', [this.selectedDay().calls, this.selectedDay().missing]))
          .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
      }.width('100%').padding(Space.lg)
    }
  }

  @Builder
  modelRow(item: UsageModel) {
    Column({ space: Space.sm }) {
      Row({ space: Space.sm }) {
        Text(item.model).fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Text(item.reported ? this.number(item.total) : t('未报告')).fontSize(14).fontColor($r('app.color.accent'))
      }.width('100%')
      Progress({ value: item.total, total: Math.max(1, this.stats.totals.total), type: ProgressType.Linear })
        .width('100%').color($r('app.color.accent')).backgroundColor($r('app.color.surface_variant'))
      Text(this.providerName(item.provider) + ' · ' + t('{0} 次请求 · {1} 次未报告', [item.calls, item.missing]))
        .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
    }.padding(Space.lg).width('100%')
  }

  @Builder
  requestRow(item: RequestUsage) {
    Column({ space: Space.sm }) {
      Row({ space: Space.sm }) {
        Text(item.model).fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Tag({ text: this.status(item), danger: item.status === 'failed' })
      }.width('100%')
      Text(this.providerName(item.provider) + ' · ' + new Date(item.startedAt).toLocaleString(getLocale()))
        .fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).width('100%')
      Text(reportedTokens(item.tokens) ? t('输入 {0} · 输出 {1}', [this.number(item.tokens!.input), this.number(item.tokens!.output)]) : t('Token 未报告'))
        .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      Button(this.expanded === item.id ? t('收起详情') : t('查看详情')).attributeModifier(Btn.textSmall)
        .onClick(() => { this.expanded = this.expanded === item.id ? '' : item.id; this.detailToolPage = 0; })
      if (this.expanded === item.id) {
        this.metric(t('用途'), this.purposeName(item.origin?.purpose || 'unclassified'))
        this.metric(t('会话'), this.sessionName(item.origin?.threadId || 'unassigned'))
        if (item.origin?.step) { this.metric(t('调用序号'), this.number(item.origin!.step!)) }
        if (item.origin?.memberName) { this.metric(t('团队成员'), item.origin!.memberName!) }
        if (item.origin?.taskTitle) { this.metric(t('任务'), item.origin!.taskTitle!) }
        if (item.origin?.attempt) { this.metric(t('尝试次数'), this.number(item.origin!.attempt!)) }
        this.metric(t('缓存读取（输入内）'), this.count(item.tokens?.cached))
        this.metric(t('缓存写入（输入内）'), this.count(item.tokens?.cacheWrite))
        this.metric(t('推理（输出内）'), this.count(item.tokens?.reasoning))
        this.metric(t('耗时'), item.status === 'running_or_unknown' ? '—' : (item.durationMs / 1000).toFixed(2) + ' s')
        this.metric(t('首字耗时'), item.firstTokenMs === undefined ? '—' : (item.firstTokenMs / 1000).toFixed(2) + ' s')
        if (reportedTokens(item.tokens) && item.firstTokenMs !== undefined && item.durationMs > item.firstTokenMs) {
          this.metric(t('输出速度'), (item.tokens!.output * 1000 / (item.durationMs - item.firstTokenMs)).toFixed(1) + ' Token/s')
        }
        ForEach((item.tools || []).slice(this.detailToolPage * 20, this.detailToolPage * 20 + 20), (tool: UsageToolActivity) => {
          this.metric(tool.remoteTool || tool.name, tool.status === 'complete' ? t('完成') : tool.status === 'failed' ? t('失败') : tool.status === 'cancelled' ? t('已取消') : t('进行中 / 结果不确定'))
        }, (tool: UsageToolActivity) => tool.id + tool.status)
        if ((item.tools?.length || 0) > 20) { this.pager(this.detailToolPage, (this.detailToolPage + 1) * 20 < (item.tools?.length || 0), () => { this.detailToolPage--; }, () => { this.detailToolPage++; }) }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(Space.lg)
  }

  private purposeName(purpose: string): string {
    const names: Record<string, string> = { 'conversation': t('对话'), 'team_planning': t('团队规划'), 'team_task': t('团队执行'),
      'compaction': t('上下文压缩'), 'title': t('标题生成'), 'memory': t('记忆提取'), 'unclassified': t('未分类') };
    return names[purpose] || t('未分类');
  }
  private groupValue(item: UsageGroup): string { return item.reported ? this.number(item.total) + ' Token' : t('未报告'); }
  private groupCaption(item: UsageGroup): string {
    return t('{0} 次调用 · {1} 次未报告', [item.calls, item.missing]);
  }
  private weekLabel(key: string): string {
    const parts = key.split('-'); const end = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]) + 6);
    return key + ' — ' + (end.getMonth() + 1) + '/' + end.getDate();
  }

  @Builder
  weekly() {
    SectionHeader({ title: t('按周统计') })
    GroupCard() {
      Column() {
        ForEach(this.stats.weeks, (week: UsagePeriod, index: number) => {
          if (index > 0) { RowDivider() }
          NavRow({ title: this.weekLabel(week.key), value: week.reported ? compactNumber(week.total) : '—', trailing: 'expand',
            active: this.expandedWeek === week.key, compId: 'usage-week-' + week.key,
            onTap: () => { this.expandedWeek = this.expandedWeek === week.key ? '' : week.key; } })
          if (this.expandedWeek === week.key) {
            Column({ space: Space.md }) {
              this.metric(t('总 Token'), this.groupValue(week))
              ForEach(week.purposes, (item: UsageGroup) => {
                this.metric(this.purposeName(item.key), this.groupValue(item))
              }, (item: UsageGroup) => item.key + ':' + this.revisionKey)
            }.width('100%').padding(Space.lg)
          }
        }, (week: UsagePeriod) => week.key + ':' + this.revisionKey)
        if (this.weekCount > 8) { this.pager(this.weekPage, (this.weekPage + 1) * 8 < this.weekCount, () => { this.weekPage--; this.expandedWeek = ''; this.applyPages(); }, () => { this.weekPage++; this.expandedWeek = ''; this.applyPages(); }) }
      }
    }
  }

  @Builder
  sessions() {
    SectionHeader({ title: t('会话用量排行') })
    ForEach(this.stats.sessions, (session: UsageSession, index: number) => {
      GroupCard() {
        Column() {
          NavRow({ title: (this.sessionPage * 10 + index + 1) + '. ' + this.sessionName(session.key), subtitle: this.groupCaption(session),
            value: session.reported ? compactNumber(session.total) + ' Token' : t('未报告'), trailing: 'expand',
            active: this.expandedSession === session.key, compId: 'usage-session-' + index,
            onTap: () => {
              this.expandedSession = this.expandedSession === session.key ? '' : session.key;
              this.expandedTurn = ''; this.turnPage = 0; this.turnRows = []; this.turnRequests = []; this.loadDetails();
            } })
          if (this.expandedSession === session.key) {
            Column({ space: Space.md }) {
              this.metric(t('输入 Token'), this.count(session.reported ? session.input : undefined))
              this.metric(t('输出 Token'), this.count(session.reported ? session.output : undefined))
              this.metric(t('Token 占比'), this.stats.totals.total > 0 && session.reported ? (session.total * 100 / this.stats.totals.total).toFixed(1) + '%' : '—')
            }.width('100%').padding(Space.lg)
            ForEach(this.turnRows, (turn: UsageGroup, turnIndex: number) => {
              RowDivider()
              NavRow({ title: turn.label || (turn.key === 'unassigned' ? t('未归属轮次') : t('轮次')),
                subtitle: this.groupCaption(turn), value: turn.reported ? compactNumber(turn.total) + ' Token' : t('未报告'), trailing: 'expand',
                active: this.expandedTurn === turn.key, compId: 'usage-turn-' + turnIndex,
                onTap: () => { this.expandedTurn = this.expandedTurn === turn.key ? '' : turn.key; this.turnRequestPage = 0; this.turnCursors = [undefined]; this.turnRequests = []; this.loadDetails(); } })
              if (this.expandedTurn === turn.key) {
                ForEach(this.turnRequests, (item: RequestUsage) => {
                  RowDivider()
                  this.requestRow(item)
                }, (item: RequestUsage) => item.id + ':' + this.revisionKey)
                this.pager(this.turnRequestPage, this.turnHasNext, () => this.moveRequests(false, true), () => this.moveRequests(true, true))
              }
            }, (turn: UsageGroup) => turn.key + ':' + this.revisionKey)
            if (this.turnCount > 10) { this.pager(this.turnPage, (this.turnPage + 1) * 10 < this.turnCount, () => { this.turnPage--; this.expandedTurn = ''; this.loadDetails(); }, () => { this.turnPage++; this.expandedTurn = ''; this.loadDetails(); }) }
          }
        }
      }
      Blank().height(Space.sm)
    }, (session: UsageSession) => session.key + ':' + this.revisionKey)
    if (this.sessionCount > 10) { this.pager(this.sessionPage, (this.sessionPage + 1) * 10 < this.sessionCount, () => { this.sessionPage--; this.expandedSession = ''; this.expandedTurn = ''; this.applyPages(); }, () => { this.sessionPage++; this.expandedSession = ''; this.expandedTurn = ''; this.applyPages(); }) }
  }

  @Builder
  activityList(items: UsageActivity[], skills: boolean) {
    GroupCard() {
      Column() {
        ForEach(items, (item: UsageActivity, index: number) => {
          if (index > 0) { RowDivider() }
          Column({ space: Space.sm }) {
            this.metric(item.label, skills ? t('{0} 轮', [item.calls]) : t('{0} 次', [item.calls]))
            if (!skills && item.failed > 0) {
              Text(t('{0} 次失败', [item.failed])).fontSize(Font.caption).fontColor($r('app.color.danger')).width('100%')
            }
          }.width('100%').padding(Space.lg)
        }, (item: UsageActivity) => JSON.stringify(item))

      }
    }
  }

  @Builder
  activities() {
    SectionHeader({ title: t('工具调用') })
    if (this.stats.tools.length > 0) { this.activityList(this.stats.tools, false) }
    else { EmptyState({ icon: $r('sys.symbol.clock'), title: t('暂无工具活动记录') }) }
    if (this.toolCount > 10) { this.pager(this.toolPage, (this.toolPage + 1) * 10 < this.toolCount, () => { this.toolPage--; this.applyPages(); }, () => { this.toolPage++; this.applyPages(); }) }
    SectionHeader({ title: t('Skill 使用轮次') })
    if (this.stats.skills.length > 0) { this.activityList(this.stats.skills, true) }
    else { EmptyState({ icon: $r('sys.symbol.clock'), title: t('暂无 Skill 活动记录') }) }
    if (this.skillCount > 10) { this.pager(this.skillPage, (this.skillPage + 1) * 10 < this.skillCount, () => { this.skillPage--; this.applyPages(); }, () => { this.skillPage++; this.applyPages(); }) }
  }

  @Builder
  pager(page: number, hasNext: boolean, previous: () => void, next: () => void) {
    if (page > 0 || hasNext) {
      Row() {
        Button(t('上一页')).attributeModifier(Btn.textSmall).enabled(page > 0 && !this.loading && !this.pageLoading).onClick(previous)
        Blank()
        Text(String(page + 1)).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
        Blank()
        Button(t('下一页')).attributeModifier(Btn.textSmall).enabled(hasNext && !this.loading && !this.pageLoading).onClick(next)
      }.width('100%').padding(Space.sm)
    }
  }

  build() {
    List({ space: 0 }) {
      ListItem() {
        Column() {
          this.filters()
          Segmented({ options: [t('总览'), t('会话'), t('活动'), t('请求')], selected: this.tab, compIdPrefix: 'usage-tab',
            onSelect: (index: number) => { this.tab = index; this.loadDetails(); } }).margin({ top: Space.md })
          if (this.loading || this.pageLoading) { LoadingProgress().width(24).height(24).margin({ top: Space.sm }) }
          if (this.error) { Banner({ text: this.error }).margin({ top: Space.md }) }
          if (this.tab === 0) {
            this.overview()
          }
          if (this.stats.totals.calls > 0 && this.tab === 0) {
            this.trend()
            SectionHeader({ title: t('按用途统计') })
            GroupCard() {
              Column({ space: Space.md }) {
                ForEach(this.stats.purposes, (item: UsageGroup) => {
                  this.metric(this.purposeName(item.key), this.groupValue(item))
                }, (item: UsageGroup) => item.key + ':' + this.revisionKey)
              }.width('100%').padding(Space.lg)
            }
            this.weekly()
            SectionHeader({ title: t('模型分布') })
            GroupCard() {
              Column() {
                ForEach(this.stats.models, (item: UsageModel, index: number) => {
                  if (index > 0) { RowDivider() }
                  this.modelRow(item)
                }, (item: UsageModel) => JSON.stringify(item))
                if (this.modelCount > 5) { this.pager(this.modelPage, (this.modelPage + 1) * 5 < this.modelCount, () => { this.modelPage--; this.applyPages(); }, () => { this.modelPage++; this.applyPages(); }) }
              }
            }
          } else if (!this.loading && this.stats.totals.calls === 0 && this.tab !== 2) {
            EmptyState({ icon: $r('sys.symbol.clock'), title: t('没有匹配的用量记录') })
          }
          if (this.tab === 1) { this.sessions() }
          if (this.tab === 2) { this.activities() }
          if (this.tab === 3) {
            Row() {
            SectionHeader({ title: t('请求明细') }).layoutWeight(1)
            Button(t('刷新')).id('usage-refresh').attributeModifier(Btn.textSmall).onClick(() => this.refresh())
            }.width('100%')
          }
        }.width('100%')
      }
      ForEach(this.tab === 3 ? this.requestRows : [], (item: RequestUsage) => {
        ListItem() { GroupCard() { this.requestRow(item) } }.margin({ bottom: Space.sm })
      }, (item: RequestUsage) => item.id + ':' + this.revisionKey)
      if (this.tab === 3) {
        ListItem() { this.pager(this.requestPage, this.requestHasNext, () => this.moveRequests(false, false), () => this.moveRequests(true, false)) }
      }
    }.width('100%').height('100%').padding({ left: Space.page, right: Space.page }).scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring).contentEndOffset(Space.xl)
      .bindSheet($$this.showFilter, this.filterSheet(), { title: { title: this.filterTitle() },
        height: SheetSize.FIT_CONTENT, dragBar: true, backgroundColor: $r('app.color.page_background') })
  }
}
