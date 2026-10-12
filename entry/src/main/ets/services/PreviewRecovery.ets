import { uiParts } from '../model/InteractiveUi';
import { PreviewRepairSource, uiFailureReport } from '../model/UiRepair';
import { Cancellation } from './Cancellation';
import { WorkspaceFiles } from './WorkspaceFiles';

// Preserve the exact failed source before asking the model for a small edit. Never overwrite a user's file.
export async function savePreviewRepair(files: WorkspaceFiles, id: string, content: string, error: Error,
  cancellation: Cancellation): Promise<string> {
  const parts = uiParts(content, false).filter((part) => part.kind === 'ui');
  const sources: PreviewRepairSource[] = [];
  if (parts.length > 8) { return uiFailureReport(error, [], 'Source preservation requires at most 8 surfaces per response.'); }
  try {
    for (const part of parts) {
      cancellation.check();
      const path = 'preview-repairs/' + id + '-' + part.key + '.jsonl';
      const saved = await files.write(path, part.content, cancellation, { version: null });
      sources.push({ surface: part.key, path: path, version: saved.version,
        retry: { tool: 'publish_preview', arguments: { path: path } } });
    }
    cancellation.check();
    return uiFailureReport(error, sources);
  } catch (storageError) {
    cancellation.check();
    // Report partial saves explicitly; never recommend a path whose write failed.
    return uiFailureReport(error, sources, (storageError as Error).message);
  }
}
