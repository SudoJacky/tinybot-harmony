export const execute: (id: string, source: string, inputJson: string) => Promise<string>;
export const cancel: (id: string) => void;
export const orchestrate: (id: string, source: string, catalog: string,
  invoke: (callId: number, name: string, argumentsJson: string) => void) => Promise<string>;
export const settle: (id: string, callId: number, output: string, error: boolean) => void;
export const cancelOrchestration: (id: string) => void;
