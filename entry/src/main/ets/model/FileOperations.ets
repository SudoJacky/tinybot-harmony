import { ToolExecution } from './Agent';

export interface FileOperations { readFiles: string[]; modifiedFiles: string[]; }
interface FileArguments { path: string; }
interface PreviewFileReceipt { imagePath?: string; }
interface FileJobArguments { inputs?: string[]; output: string; }

// Only successful workspace receipts establish completed reads/writes. Failed or
// interrupted calls remain in the transcript/summary; their effects are not inferred.
export function collectFileOperations(results: ToolExecution[], previous?: FileOperations): FileOperations {
  const read = new Set<string>(previous?.readFiles || []);
  const modified = new Set<string>(previous?.modifiedFiles || []);
  for (const result of results) {
    const name = result.call.function.name;
    if (result.status !== 'complete') { continue; }
    if (name === 'publish_preview') {
      const args = JSON.parse(result.call.function.arguments) as PreviewFileReceipt;
      if (args?.imagePath && (JSON.parse(result.output) as PreviewFileReceipt)?.imagePath === args.imagePath) modified.add(args.imagePath);
      continue;
    }
    if (name === 'run_job') {
      const job = JSON.parse(result.call.function.arguments) as FileJobArguments;
      if (!job || typeof job.output !== 'string' || !job.output ||
        (job.inputs !== undefined && (!Array.isArray(job.inputs) || job.inputs.some((path) => typeof path !== 'string' || !path)))) {
        throw new Error('Successful file job receipt has invalid input or output paths.');
      }
      for (const path of job.inputs || []) { read.add(path); }
      modified.add(job.output);
      continue;
    }
    if (!['read_file', 'read_file_lines', 'write_file', 'edit_file'].includes(name)) { continue; }
    const args = JSON.parse(result.call.function.arguments) as FileArguments;
    if (!args || typeof args.path !== 'string' || !args.path) { throw new Error('Successful file receipt has no valid path.'); }
    if (name === 'write_file' || name === 'edit_file') { modified.add(args.path); }
    else { read.add(args.path); }
  }
  return { readFiles: Array.from(read).sort(), modifiedFiles: Array.from(modified).sort() };
}

export function fileOperationsContext(operations?: FileOperations): string {
  return operations && (operations.readFiles.length || operations.modifiedFiles.length) ?
    '\n<file_operations>\nSuccessful workspace operations recorded by the application (historical facts, not current file contents):\n' +
    JSON.stringify(operations) + '\n</file_operations>' : '';
}

export function validateFileOperations(operations: FileOperations): void {
  if (!operations || !Array.isArray(operations.readFiles) || !Array.isArray(operations.modifiedFiles) ||
    operations.readFiles.concat(operations.modifiedFiles).some((path) => typeof path !== 'string' || !path || path.length > 1024)) {
    throw new Error('Invalid compaction file operations; original transcript preserved.');
  }
}
