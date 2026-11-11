import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { builtinWidget, builtinWidgetSpec } from '../model/BuiltinWidgets';
import { PanelEntry, PanelSpec, parsePanelSpec } from '../model/LifePanel';
import { resolvePanelInputs } from '../model/PanelContract';
import { getLocale, t } from '../model/I18n';
import { webUiPage } from '../model/WebUi';
import { BALANCE_PANEL_HTML } from '../model/BalancePanelTemplate';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { LifePanels } from './LifePanels';
import { providerBalanceDefinition } from './ProviderBalanceCatalog';
import { Cancellation } from './Cancellation';
import { PanelValidationStorage } from './PanelValidationStorage';
import { WebUiPreflight } from './WebUiPreflight';

// Packaged HTML follows the same renderer, storage and source contracts as authored cards.
export class BuiltinWidgets {
  private context: common.Context;
  constructor(context: common.Context) { this.context = context; }
  private async resource(name: string): Promise<string> {
    const bytes = await this.context.resourceManager.getRawFileContent('builtin-widgets/' + name);
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }
  async definition(id: string): Promise<PanelSpec> {
    const widget = builtinWidget(id);
    let spec: PanelSpec;
    if (id === 'balance') {
      const definition = providerBalanceDefinition();
      if (!definition) { throw new Error(t('请先在模型服务设置中配置余额查询。')); }
      spec = definition; spec.title = widget.title; spec.view = webUiPage('balance.html', BALANCE_PANEL_HTML);
    } else {
      const parts = await Promise.all([this.resource(id + '.html'), this.resource('base.css'), this.resource('base.js'),
        id.startsWith('guide-') ? this.resource('guide.js') : Promise.resolve(''),
        id.startsWith('guide-') ? this.resource('guide.css') : Promise.resolve('')]);
      const html = parts[0].replace('/*BUILTIN_STYLE*/', () => parts[1] + '\n' + parts[4]).replace('/*BUILTIN_RUNTIME*/', () => parts[2] + '\n' + parts[3]);
      spec = builtinWidgetSpec(id, html);
    }
    spec.view!.height = widget.height * 44 - 12;
    return parsePanelSpec(JSON.stringify(spec));
  }
  async add(id: string, workspaceId: string, cancellation: Cancellation, width: number = 344): Promise<PanelEntry> {
    const spec = await this.definition(id); cancellation.check();
    // Probe edits use detached storage; installing a checklist never adds its test item.
    await WebUiPreflight.validatePanel(JSON.stringify(spec.view), new PanelValidationStorage({ value: null, revision: 'initial' }),
      { data: spec.data, inputs: resolvePanelInputs(spec.inputs), title: spec.title, status: 'ready', canRefresh: !!spec.source, locale: getLocale() }, cancellation,
      { width: width, height: spec.view!.height, checks: spec.checks || [] });
    cancellation.check();
    const filesDir = this.context.getApplicationContext().filesDir;
    await new WorkspaceStore(filesDir).requireWorkspace(workspaceId);
    const panels = new LifePanels(filesDir), panelId = panels.createId();
    const panel = await panels.repository(workspaceId).publish(panelId, spec, 'builtin-widgets/' + id + '.html', '', false, cancellation);
    return { workspaceId: workspaceId, panel: panel };
  }
}
