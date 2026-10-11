import { AgentStep } from '../model/Agent';

function canonical(value: Object): string {
  if (value === null || typeof value !== 'object') { return JSON.stringify(value); }
  if (Array.isArray(value)) { return '[' + (value as Object[]).map((item) => canonical(item)).join(',') + ']'; }
  const record = value as Record<string, Object>;
  return '{' + Object.keys(record).sort().map((key) => JSON.stringify(key) + ':' + canonical(record[key])).join(',') + '}';
}

export class RepeatToolReminder {
  private key: string = '';
  private count: number = 0;
  reset(): void { this.key = ''; this.count = 0; }
  observe(step: AgentStep): string | undefined {
    let reminder: string | undefined = undefined;
    for (const parent of step.tools) {
      for (const tool of parent.children || [parent]) {
        const name = tool.call.function.name;
        if (['team_wait', 'request_user_input'].includes(name) || !['complete', 'failed'].includes(tool.status)) { continue; }
        let args: string;
        try { args = canonical(JSON.parse(tool.call.function.arguments) as Object); }
        catch (_) { args = tool.call.function.arguments; }
        const key = name + '\n' + args;
        this.count = key === this.key ? this.count + 1 : 1; this.key = key;
        if ([3, 5, 8].includes(this.count)) {
          reminder = 'Runtime reminder: the same tool and arguments have been called ' + this.count +
            ' consecutive times. Check whether progress is being made. Inspect existing results, change the approach, or explain the blocker; do not repeat completed side effects. Tool name (data): ' + JSON.stringify(name);
        }
      }
    }
    return reminder;
  }
}
