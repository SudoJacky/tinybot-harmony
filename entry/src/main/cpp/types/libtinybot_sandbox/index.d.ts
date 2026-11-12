export const execute: (id: string, source: string, inputJson: string) => Promise<string>;
export const cancel: (id: string) => void;
export const orchestrate: (id: string, source: string, catalog: string,
  invoke: (callId: number, name: string, argumentsJson: string) => void, workspaceCode?: boolean) => Promise<string>;
export const settle: (id: string, callId: number, output: string, error: boolean) => void;
export const cancelOrchestration: (id: string) => void;
export interface LocalProcessReceipt {
  status: string;
  error: string;
  stdout: string;
  stderr: string;
  durationMs: number;
  exitCode?: number;
  signal?: number;
  outputTruncated: boolean;
}
export const localProcessAvailable: (libraryDir: string) => boolean;
export const runLocalProcess: (id: string, libraryDir: string, runtime: string, code: string, input: string,
  timeoutMs: number) => Promise<LocalProcessReceipt>;
export const cancelLocalProcess: (id: string) => void;
