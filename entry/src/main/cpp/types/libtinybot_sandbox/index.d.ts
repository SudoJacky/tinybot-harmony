export const execute: (id: string, source: string, inputJson: string) => Promise<string>;
export const cancel: (id: string) => void;
// Exported only in builds containing the signed TCI library for this ABI.
export const startLinux: (id: string, privateJobDir: string, timeoutSeconds: number, memoryMiB: number) => Promise<string>;
export const startLinuxConsole: (id: string, privateJobDir: string, timeoutSeconds: number, memoryMiB: number) => Promise<string>;
export const cancelLinux: (id: string) => void;
export const startEmbeddedLinux: (privateJobDir: string, memoryMiB: number) => void;
export const linuxMemoryLimit: () => number;
export const linuxStorageBytes: (path: string) => number;
export const packLinuxDirectory: (path: string, guestName: string, fd: number, offset: number) => Promise<number>;
export const cancelLinuxDirectory: () => void;
export const orchestrate: (id: string, source: string, catalog: string,
  invoke: (callId: number, name: string, argumentsJson: string) => void, workspaceCode?: boolean) => Promise<string>;
export const settle: (id: string, callId: number, output: string, error: boolean) => void;
export const cancelOrchestration: (id: string) => void;
