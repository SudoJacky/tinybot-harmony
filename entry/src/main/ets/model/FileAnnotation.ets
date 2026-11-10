export type FileAnnotationKind = 'element' | 'slide' | 'cells' | 'text';

export interface FileAnnotationTarget {
  kind: FileAnnotationKind;
  location: string;
  excerpt?: string;
  slide?: number;
  elementId?: string;
}

export interface FileAnnotation extends FileAnnotationTarget {
  id: string;
  path: string;
  version: string;
  comment: string;
}

export const MAX_FILE_ANNOTATIONS = 20;
export const MAX_ANNOTATION_COMMENT = 2000;

export function validateFileAnnotations(items: FileAnnotation[]): void {
  if (!Array.isArray(items) || items.length > MAX_FILE_ANNOTATIONS) { throw new Error('Invalid file annotation count'); }
  const ids = new Set<string>();
  for (const item of items) {
    if (!item || typeof item.id !== 'string' || !item.id || ids.has(item.id) ||
      typeof item.path !== 'string' || !item.path || item.path.length > 1024 ||
      typeof item.version !== 'string' || !item.version || item.version.length > 160 ||
      !['element', 'slide', 'cells', 'text'].includes(item.kind) ||
      typeof item.location !== 'string' || !item.location || item.location.length > 1000 ||
      (item.excerpt !== undefined && (typeof item.excerpt !== 'string' || item.excerpt.length > 1000)) ||
      (item.slide !== undefined && (item.kind !== 'slide' || !Number.isSafeInteger(item.slide) || item.slide < 1)) ||
      (item.elementId !== undefined && (item.slide === undefined || typeof item.elementId !== 'string' || !item.elementId || item.elementId.length > 256)) ||
      typeof item.comment !== 'string' || !item.comment.trim() || item.comment.length > MAX_ANNOTATION_COMMENT) {
      throw new Error('Invalid file annotation');
    }
    ids.add(item.id);
  }
}

export function fileAnnotationContext(items?: FileAnnotation[]): string {
  if (!items?.length) { return ''; }
  return JSON.stringify({ type: 'file_annotations', annotations: items.map((item): FileAnnotationContext => {
    return { path: item.path, version: item.version, kind: item.kind, location: item.location,
      excerpt: item.excerpt, slide: item.slide, elementId: item.elementId, comment: item.comment };
  }) });
}

interface FileAnnotationContext extends FileAnnotationTarget {
  path: string;
  version: string;
  comment: string;
}
