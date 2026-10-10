import { McpServer, ProductivityData, validateProductivity } from '../model/Productivity';
import { McpRequest, saveMcpCandidate } from '../model/ResourceManagement';
import { Cancellation } from './Cancellation';
import { CredentialVault } from './ProfileSettings';

// Secrets are accepted only from the native editor, never from a model tool schema.
export interface McpSettingsCommand extends McpRequest {
  token?: string;
  enabled?: boolean;
  verify?: boolean;
}
export interface McpSettingsResult { id: string; tools: number; warning: string; }
export interface McpSettingsHost {
  current: () => ProductivityData;
  check: () => void;
  prepare: (server: McpServer, request: McpRequest, cancellation: Cancellation) => Promise<McpServer>;
  test: (server: McpServer, cancellation: Cancellation) => Promise<number>;
  commit: (data: ProductivityData, id: string, action: string) => Promise<void>;
}

// Both settings and chat commit configuration before retiring the previous credential.
export class McpSettings {
  private credentials: CredentialVault;
  private createId: () => string;
  private report: (message: string) => void;
  constructor(credentials: CredentialVault, createId: () => string, report: (message: string) => void) {
    this.credentials = credentials; this.createId = createId; this.report = report;
  }
  async execute(request: McpSettingsCommand, host: McpSettingsHost, cancellation: Cancellation): Promise<McpSettingsResult> {
    cancellation.check(); host.check();
    const before = host.current();
    const previous = before.servers.find((item) => item.id === request.id);
    if (request.id && !previous) { throw new Error('MCP server does not exist: ' + request.id); }
    const id = previous?.id || this.createId();
    let createdAlias = ''; let count = 0;
    try {
      let next: ProductivityData;
      if (request.action === 'test') {
        if (!previous) { throw new Error('MCP server does not exist.'); }
        return { id: id, tools: await host.test(previous, cancellation), warning: '' };
      }
      if (request.action === 'save') {
        if (request.auth === 'keep' && (!previous || previous.url !== request.url)) {
          throw new Error('Keeping credentials requires an existing server with the same URL.');
        }
        if (!['none', 'keep', 'bearer', 'oauth'].includes(request.auth || '')) { throw new Error('Invalid MCP authentication mode.'); }
        let server: McpServer = { id: id, name: request.name || '', url: request.url || '',
          enabled: request.enabled === undefined ? true : request.enabled,
          credentialAlias: request.auth === 'keep' ? previous?.credentialAlias || '' : '',
          authType: request.auth === 'keep' ? previous?.authType : undefined };
        saveMcpCandidate(before, server);
        if (request.auth === 'keep' && server.credentialAlias) { await this.credentials.read(server.credentialAlias); }
        if (request.auth === 'bearer' && request.token !== undefined) {
          if (!request.token.trim()) { throw new Error('Bearer token is required.'); }
          createdAlias = 'tinybot-mcp-' + this.createId();
          await this.credentials.write(createdAlias, request.token.trim()); server.credentialAlias = createdAlias;
        } else if (request.auth === 'bearer' || request.auth === 'oauth') {
          server = await host.prepare(server, request, cancellation);
          createdAlias = server.credentialAlias !== previous?.credentialAlias ? server.credentialAlias : '';
        }
        if (request.verify !== false) { count = await host.test(server, cancellation); }
        next = saveMcpCandidate(host.current(), server);
      } else {
        if (!previous || !['remove', 'enable', 'disable'].includes(request.action)) { throw new Error('Invalid MCP change.'); }
        next = JSON.parse(JSON.stringify(host.current())) as ProductivityData;
        if (request.action === 'remove') { next.servers = next.servers.filter((item) => item.id !== id); }
        else {
          const target = next.servers.find((item) => item.id === id);
          if (!target) { throw new Error('MCP server does not exist.'); }
          target.enabled = request.action === 'enable';
        }
        validateProductivity(next);
      }
      cancellation.check(); host.check();
      await host.commit(next, id, request.action);
      createdAlias = '';
    } catch (error) {
      let message = (error as Error).message;
      if (createdAlias) {
        try { await this.credentials.remove(createdAlias); }
        catch (cleanup) { message += '; MCP credential rollback failed: ' + (cleanup as Error).message; }
      }
      this.report('MCP setup failed: id=' + id + ' ' + message); throw new Error(message);
    }
    let warning = '';
    if (previous?.credentialAlias && !host.current().servers.some((item) => item.credentialAlias === previous.credentialAlias)) {
      try { await this.credentials.remove(previous.credentialAlias); }
      catch (error) {
        warning = 'Configuration saved, but old credential cleanup failed: ' + (error as Error).message;
        this.report(warning);
      }
    }
    return { id: id, tools: count, warning: warning };
  }
}
