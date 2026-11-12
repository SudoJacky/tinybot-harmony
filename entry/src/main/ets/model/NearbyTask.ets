import { InputForm, parseForm } from './RichArtifacts';
import { PendingInput, validatePendingInputs } from './PendingInput';
import { ModelReference, validateReference } from './ProviderProfiles';

export interface TaskApproval {
  id: string;
  threadId: string;
  title: string;
  details: string;
  form?: InputForm;
}
export interface NearbyTaskState {
  modelRef?: ModelReference;
  runId: string;
  running: boolean;
  acceptingSteering: boolean;
  queuePaused: boolean;
  pendingInputs: PendingInput[];
  approval?: TaskApproval;
  error: string;
}
export interface NearbyTaskControl {
  action: 'stop' | 'resume' | 'remove-input' | 'approve' | 'form' | 'model';
  modelRef?: ModelReference;
  runId: string;
  inputId?: string;
  approvalId?: string;
  allowed?: boolean;
  values?: string[];
}
export interface NearbyTaskStatus {
  threadId: string;
  connected: boolean;
  updatedAt: number;
  task?: NearbyTaskState;
}

export function parseNearbyTask(text: string): NearbyTaskState {
  const task = JSON.parse(text) as NearbyTaskState;
  if (!task || typeof task.runId !== 'string' || typeof task.running !== 'boolean' ||
    typeof task.acceptingSteering !== 'boolean' || typeof task.queuePaused !== 'boolean' || typeof task.error !== 'string') {
    throw new Error('Invalid nearby task state');
  }
  validatePendingInputs(task.pendingInputs);
  if (task.modelRef) { validateReference(task.modelRef); }
  const approval = task.approval;
  if (approval) {
    if (typeof approval.id !== 'string' || !approval.id || typeof approval.threadId !== 'string' ||
      typeof approval.title !== 'string' || typeof approval.details !== 'string') { throw new Error('Invalid nearby approval'); }
    if (approval.form) { parseForm(JSON.stringify(approval.form)); }
  }
  return task;
}
