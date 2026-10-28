import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { officeText, pdfText } from './DocumentText';
import { copyOpenFileBytes, readBounded } from './FileBytes';
import { readUtf8File } from './TextFiles';
import { Cancellation } from './Cancellation';

export function isDocumentPath(path: string): boolean { return /\.(pdf|docx|xlsx|pptx)$/i.test(path); }

export async function readDocumentFile(fd: number, path: string, temporaryDir: string, cancellation: Cancellation): Promise<string> {
  cancellation.check();
  if (!isDocumentPath(path)) { return readUtf8File(fd, cancellation); }
  if (!/\.pdf$/i.test(path)) {
    // The ZIP parser needs the archive bytes; size comes from the file, not a product limit.
    const bytes = await readBounded(fd, (await fs.stat(fd)).size);
    cancellation.check();
    return officeText(bytes, cancellation);
  }
  // PDFKit takes a path, so use a private snapshot even for a shared-folder URI.
  const temporary = temporaryDir + '/.tinybot-pdf-' + util.generateRandomUUID() + '.pdf';
  try { await copyOpenFileBytes(fd, temporary); cancellation.check(); return pdfText(temporary, cancellation); }
  finally { if (await fs.access(temporary)) { await fs.unlink(temporary); } }
}
