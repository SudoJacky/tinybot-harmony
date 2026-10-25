import { ToolCall, ToolDefinition, ToolProperty } from '../model/Agent';
import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { toolTitle } from '../model/ToolPresentation';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { ContextEntry } from '../model/ContextProjection';

// Only the explicit opt-in discovery mode uses this subset; default sessions expose the full authorized catalog.
const DIRECT_TOOLS: string[] = ['read_file', 'write_file', 'edit_file', 'orchestrate',
  'publish_preview', 'present_files',
  'read_attachment', 'read_reference', 'team_complete_task'];
interface SearchArguments { query: string; }
interface ToolSummary { name: string; description: string; }
interface ToolMatch { tool: ToolDefinition; score: number; }
const STOP_WORDS: Set<string> = new Set<string>(['a', 'an', 'and', 'are', 'as', 'at', 'be', 'by', 'for', 'from',
  'in', 'is', 'it', 'of', 'on', 'or', 'that', 'the', 'this', 'to', 'with']);

// Same English splitting and plural folding as pi; overlapping Chinese bigrams need no dictionary.
function tokenize(text: string): string[] {
  const chunks = text.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .toLowerCase().match(/[a-z0-9]+|[\u3400-\u9fff]+/g) || [];
  const terms: string[] = [];
  for (const chunk of chunks) {
    if (/^[\u3400-\u9fff]/.test(chunk)) {
      if (chunk.length === 1) { terms.push(chunk); }
      for (let index = 0; index < chunk.length - 1; index++) { terms.push(chunk.slice(index, index + 2)); }
    } else if (!STOP_WORDS.has(chunk)) {
      if (chunk.length > 4 && chunk.endsWith('ies')) { terms.push(chunk.slice(0, -3) + 'y'); }
      else if (chunk.length > 4 && /(ches|shes|sses|xes|zes)$/.test(chunk)) { terms.push(chunk.slice(0, -2)); }
      else if (chunk.length > 3 && chunk.endsWith('s') && !chunk.endsWith('ss')) { terms.push(chunk.slice(0, -1)); }
      else { terms.push(chunk); }
    }
  }
  return terms;
}

function schemaText(schema: ToolProperty, parts: string[]): void {
  if (schema.description) { parts.push(schema.description); }
  if (schema.properties) {
    for (const name of Object.keys(schema.properties)) { parts.push(name); schemaText(schema.properties[name], parts); }
  }
  if (schema.items) { schemaText(schema.items, parts); }
  if (schema.anyOf) { for (const variant of schema.anyOf) { schemaText(variant, parts); } }
}

function rankTools(query: string, tools: ToolDefinition[]): ToolMatch[] {
  const terms = Array.from(new Set<string>(tokenize(query)));
  if (terms.length === 0 || tools.length === 0) { return []; }
  const documents = tools.map((tool): Map<string, number> => {
    const name = tool.function.name;
    const parts = [name, name.replace(/_/g, ' '), tool.function.description, summary(tool).description];
    schemaText({ description: '', properties: tool.function.parameters.properties }, parts);
    const counts = new Map<string, number>();
    for (const term of tokenize(parts.join(' '))) { counts.set(term, (counts.get(term) || 0) + 1); }
    return counts;
  });
  const lengths = documents.map((counts) => Array.from(counts.values()).reduce((sum, count) => sum + count, 0));
  const averageLength = lengths.reduce((sum, length) => sum + length, 0) / tools.length || 1;
  const idf = terms.map((term) => {
    const frequency = documents.filter((counts) => counts.has(term)).length;
    return Math.log(1 + (tools.length - frequency + 0.5) / (frequency + 0.5));
  });
  // Okapi BM25, matching pi's k1=1.2, b=0.75. Stable ties retain catalog order.
  return tools.map((tool, index): ToolMatch => {
    const norm = 1.2 * (1 - 0.75 + 0.75 * lengths[index] / averageLength);
    const score = terms.reduce((sum: number, term: string, termIndex: number) => {
      const count = documents[index].get(term) || 0;
      return sum + idf[termIndex] * count * 2.2 / (count + norm);
    }, 0);
    return { tool: tool, score: score };
  }).filter((match) => match.score > 0).sort((a: ToolMatch, b: ToolMatch) => b.score - a.score).slice(0, 6);
}

function summary(tool: ToolDefinition): ToolSummary {
  return { name: tool.function.name, description: tool.promptSnippet || toolTitle(tool.function.name) };
}

function searchDefinition(deferred: ToolDefinition[]): ToolDefinition {
  return { type: 'function', executionMode: 'sequential', function: {
    name: 'tool_search',
    description: 'Discover specialized tools before using them. Search by exact tool name or keywords; matching schemas and usage instructions appear in the next request. ' +
      'Use an empty query to list available names. Only currently authorized tools can be loaded. Available: ' +
      deferred.map((tool) => { const item = summary(tool); return item.name + ': ' + item.description; }).join('; '),
    parameters: { type: 'object', properties: { 'query': { type: 'string', description: 'Tool name or keywords; empty string lists names.', maxLength: 300 } },
      required: ['query'], additionalProperties: false }
  } };
}

// Shared by request preparation and the context inspector; discovery changes visibility, never permission.
export function discoveredToolDefinitions(catalog: ToolDefinition[], loaded: string[] = [], discovery: boolean = false): ToolDefinition[] {
  if (catalog.some((tool) => tool.function.name === 'tool_search')) {
    throw new ToolFailure('INTERNAL_ERROR', 'Reserved tool name: tool_search', 'inspect_error');
  }
  const ordered = catalog.slice().sort((a, b) => a.function.name < b.function.name ? -1 : a.function.name > b.function.name ? 1 : 0);
  if (!discovery) { return ordered; }
  const direct = ordered.filter((tool) => DIRECT_TOOLS.includes(tool.function.name));
  const deferred = ordered.filter((tool) => !DIRECT_TOOLS.includes(tool.function.name));
  const initial = deferred.length > 0 ? direct.concat([searchDefinition(deferred)]) : direct;
  // Once exposed, declarations keep their position. Newly discovered schemas follow the existing list.
  return initial.concat(loaded.flatMap((name) => deferred.filter((tool) => tool.function.name === name)));
}

interface DiscoveryResult { loaded?: string[]; }

// Discovery receipts are the durable authority; revocation is enforced by the current inner catalog.
export function discoveredToolNames(entries: ContextEntry[]): string[] {
  const loaded = new Set<string>();
  for (const entry of entries) {
    const calls = new Set<string>(entry.messages.flatMap((message) => message.toolCalls || []).map((call) => call.id));
    for (const receipt of entry.results || []) {
      // Orchestration children execute through their own catalog without exposing root schemas.
      if (!calls.has(receipt.call.id) || ['pending', 'cancelled'].includes(receipt.status)) { continue; }
      if (receipt.call.function.name === 'tool_search') {
        if (receipt.status !== 'complete') { continue; }
        const result = JSON.parse(receipt.output) as DiscoveryResult;
        if (result.loaded !== undefined) {
          if (!Array.isArray(result.loaded) || result.loaded.some((name) => typeof name !== 'string')) {
            throw new ToolFailure('INVALID_RESULT', 'Invalid saved tool discovery receipt.', 'inspect_result');
          }
          for (const name of result.loaded) { loaded.add(name); }
        }
      } else { loaded.add(receipt.call.function.name); }
    }
  }
  return Array.from(loaded);
}

export class ToolDiscovery implements AgentTools {
  private inner: AgentTools;
  private loaded: Set<string> = new Set<string>();
  private discovery: boolean;
  // Production sessions expose the complete policy-filtered catalog. Search remains explicit opt-in.
  constructor(inner: AgentTools, loaded: string[] = [], discovery: boolean = false) {
    this.inner = inner; this.loaded = new Set<string>(loaded); this.discovery = discovery;
  }
  definitions(): ToolDefinition[] { return discoveredToolDefinitions(this.inner.definitions(), Array.from(this.loaded), this.discovery); }
  executionDefinitions(): ToolDefinition[] {
    return this.inner.definitions().concat(this.definitions().filter((tool) => tool.function.name === 'tool_search'));
  }
  beforeFinish(cancellation: Cancellation): Promise<string | undefined> {
    return this.inner.beforeFinish ? this.inner.beforeFinish(cancellation) : Promise.resolve(undefined);
  }
  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    if (call.function.name !== 'tool_search') {
      this.loaded.add(call.function.name);
      return this.inner.execute(call, cancellation, context);
    }
    if (!this.discovery) {
      throw new ToolFailure('TOOL_UNAVAILABLE', 'tool_search is not enabled. Enabled tools are already provided directly.', 'check_available_tools');
    }
    const args = parseToolArguments(call.function.arguments) as SearchArguments;
    if (!args || Array.isArray(args) || typeof args.query !== 'string' || args.query.length > 300 || Object.keys(args).some((key) => key !== 'query')) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Expected a query string of at most 300 characters.', 'fix_arguments');
    }
    const catalog = this.inner.definitions();
    const deferred = catalog.filter((tool) => !DIRECT_TOOLS.includes(tool.function.name));
    if (args.query.trim().length === 0) { return JSON.stringify({ tools: deferred.map(summary) }); }
    const matches = rankTools(args.query, deferred);
    for (const match of matches) { this.loaded.add(match.tool.function.name); }
    return JSON.stringify({ loaded: matches.map((match) => match.tool.function.name),
      message: matches.length > 0 ? 'Schemas and usage instructions are available in the next request.' : 'No matching authorized tool. Use an exact tool name or an empty query to list available tools.' });
  }
}
