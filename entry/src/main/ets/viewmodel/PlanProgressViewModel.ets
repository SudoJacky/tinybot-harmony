import { AgentStep, ToolExecution } from '../model/Agent';
import { PlanItem, parsePlan } from '../model/RichArtifacts';
import { t } from '../model/I18n';

// One instance per assistant message; presentation state never enters the saved transcript.
@Observed
export class PlanProgressViewModel {
  steps: PlanItem[] = [];
  explanation: string = '';
  error: string = '';
  expanded: boolean = false;
  active: boolean = false;
  private source: string = '';
  private callId: string = '';

  get available(): boolean { return this.steps.length > 0 || this.error.length > 0; }
  get completed(): number { return this.steps.filter((item) => item.status === 'completed').length; }
  get finished(): boolean { return this.steps.length > 0 && this.completed === this.steps.length; }
  get running(): boolean { return this.active && this.available && !this.finished && !this.error; }
  get currentStep(): string { return this.steps.find((item) => item.status === 'in_progress')?.step || ''; }

  update(steps: AgentStep[], status: string): void {
    this.active = status === 'generating';
    let latest: ToolExecution | undefined = undefined;
    for (const step of steps) {
      for (const tool of step.tools) {
        if (tool.call.function.name === 'update_plan' && tool.status === 'complete') { latest = tool; }
      }
    }
    const id = latest?.call.id || ''; const output = latest?.output || '';
    if (id === this.callId && output === this.source) { return; }
    this.callId = id; this.source = output; this.error = ''; this.steps = []; this.explanation = '';
    if (!latest) { return; }
    try {
      const plan = parsePlan(output); this.steps = plan.steps; this.explanation = plan.explanation || '';
    } catch (error) {
      // Corrupt history must be visible, rather than silently showing an older plan as current.
      this.error = t('计划读取失败：') + (error as Error).message;
    }
  }
}
