export const execute: (id: string, source: string, inputJson: string) => Promise<string>;
export const cancel: (id: string) => void;
