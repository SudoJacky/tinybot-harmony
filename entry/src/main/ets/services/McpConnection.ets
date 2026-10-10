import { Cancellation } from './Cancellation';
import { McpServer } from '../model/Productivity';

export interface McpToolInfo { name: string; description?: string; inputSchema: Object; }
export interface McpConnection {
  list(cancellation: Cancellation): Promise<McpToolInfo[]>;
  call(name: string, args: Object, cancellation: Cancellation): Promise<Object>;
}
export type McpConnectionFactory = (server: McpServer) => McpConnection;
