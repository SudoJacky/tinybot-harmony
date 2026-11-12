import { Attachment, validateAttachments } from './Productivity';
import { ThreadReference, validateThreadReferences } from './ThreadReferences';
import { ModelReference, validateReference } from './ProviderProfiles';

export interface NearbyAsset { attachment: Attachment; digest: string; }
export interface NearbyInput {
  attachments?: Attachment[];
  references?: ThreadReference[];
  projectId?: string;
  modelRef?: ModelReference;
}

export function validateNearbyInput(input: NearbyInput): void {
  if (!input || typeof input !== 'object') { throw new Error('Invalid nearby input'); }
  if (input.attachments !== undefined) { validateAttachments(input.attachments); }
  if (input.references !== undefined) { validateThreadReferences(input.references); }
  if (input.projectId !== undefined && !/^[A-Za-z0-9_-]{1,128}$/.test(input.projectId)) { throw new Error('Invalid nearby project'); }
  if (input.modelRef !== undefined) { validateReference(input.modelRef); }
}
