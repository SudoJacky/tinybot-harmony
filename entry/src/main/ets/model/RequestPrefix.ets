import { ModelMessage, ToolDefinition, toolSchemas } from './Agent';

export interface RequestPrefixDiagnostics {
  change: string;
  commonMessages: number;
  sharedCharacters: number;
  systemHash: number;
  toolsHash: number;
}

// Fingerprints are diagnostics only; prefix equality always compares the original strings.
function fingerprint(text: string): number {
  let hash = 2166136261;
  for (let index = 0; index < text.length; index++) { hash = Math.imul(hash ^ text.charCodeAt(index), 16777619); }
  return hash >>> 0;
}

export class RequestPrefix {
  private messages: string[] = [];
  private tools: string = '';
  private system: string = '';
  observe(messages: ModelMessage[], tools: ToolDefinition[], serialized?: string[]): RequestPrefixDiagnostics {
    const next = serialized || messages.map((message) => JSON.stringify(message));
    const schemas = JSON.stringify(toolSchemas(tools));
    const system = messages.filter((message) => message.role === 'system').map((message) => message.content).join('\n\n');
    let common = 0; let shared = 0;
    while (common < Math.min(next.length, this.messages.length) && next[common] === this.messages[common]) {
      shared += next[common].length; common++;
    }
    const change = this.tools.length === 0 ? 'cold' : schemas !== this.tools ? 'tools' : system !== this.system ? 'system' :
      common === this.messages.length ? 'append' : 'history';
    const result: RequestPrefixDiagnostics = { change: change, commonMessages: common, sharedCharacters: shared,
      systemHash: fingerprint(system), toolsHash: fingerprint(schemas) };
    this.messages = next; this.tools = schemas; this.system = system;
    return result;
  }
}
