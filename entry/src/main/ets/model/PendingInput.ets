import { t } from './I18n';
export type InputMode = 'steer' | 'followUp';
export const MAX_PENDING_INPUTS: number = 20;
export const MAX_INPUT_TEXT: number = 24000;

export interface PendingInput {
  id: string;
  mode: InputMode;
  text: string;
}

export function validatePendingInput(input: PendingInput): void {
  if (!input || typeof input.id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(input.id) ||
    (input.mode !== 'steer' && input.mode !== 'followUp') || typeof input.text !== 'string' ||
    input.text.trim().length === 0 || input.text.length > MAX_INPUT_TEXT) {
    throw new Error(t("待发送指令无效，正文需要 1 至 24000 字符。"));
  }
}

export function validatePendingInputs(inputs: PendingInput[]): void {
  if (!Array.isArray(inputs) || inputs.length > MAX_PENDING_INPUTS) { throw new Error(t("每段对话最多保留 20 条待发送指令。")); }
  const ids = new Set<string>();
  for (const input of inputs) {
    validatePendingInput(input);
    if (ids.has(input.id)) { throw new Error(t("待发送指令 ID 重复。")); }
    ids.add(input.id);
  }
}

// Steering has priority; both lanes preserve insertion order. Paused queues are never drained.
export function nextPendingInput(inputs: PendingInput[], paused: boolean, steeringOnly: boolean = false): PendingInput | undefined {
  if (paused) { return undefined; }
  return inputs.find((input: PendingInput) => input.mode === 'steer') || (steeringOnly ? undefined : inputs[0]);
}
