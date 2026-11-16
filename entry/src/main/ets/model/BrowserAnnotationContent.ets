import { AnnotationPage, BrowserPropertyChange } from './BrowserAnnotation';
import { t } from './I18n';

export interface BrowserAnnotationContent {
  url: string;
  title: string;
  note: string;
  element?: BrowserAnnotationTarget;
  changes?: BrowserPropertyChange[];
}

interface BrowserAnnotationTarget { tag: string; label: string; location: string; }
export const MAX_BROWSER_ANNOTATION_NOTE: number = 4000;

export function browserAnnotationContent(page: AnnotationPage, note: string): BrowserAnnotationContent {
  const result: BrowserAnnotationContent = { url: page.url.slice(0, 8192), title: page.title.slice(0, 300), note: note.trim() };
  if (page.element) { result.element = { tag: page.tag || '', label: page.element.label, location: page.element.location }; }
  if (page.changes?.length) { result.changes = page.changes; }
  return result;
}

export function validBrowserPropertyChanges(changes: BrowserPropertyChange[]): boolean {
  if (!Array.isArray(changes) || changes.length > 12) { return false; }
  const properties = new Set<string>();
  for (const change of changes) {
    if (!change || typeof change.property !== 'string' || !/^[a-z-]{1,24}$/.test(change.property) ||
      properties.has(change.property) || !boundedText(change.before, 160) || !boundedText(change.after, 160)) { return false; }
    properties.add(change.property);
  }
  return true;
}

function boundedText(value: string, limit: number): boolean {
  return typeof value === 'string' && value.length <= limit && !value.includes('\u0000');
}

export function validBrowserAnnotation(content: BrowserAnnotationContent): boolean {
  return !!content && boundedText(content.url, 8192) && boundedText(content.title, 300) &&
    boundedText(content.note, MAX_BROWSER_ANNOTATION_NOTE) &&
    (content.element === undefined || (!!content.element && boundedText(content.element.tag, 80) &&
      boundedText(content.element.label, 160) && boundedText(content.element.location, 1000))) &&
    (content.changes === undefined || (!!content.element && validBrowserPropertyChanges(content.changes)));
}

export function browserAnnotationText(page: BrowserAnnotationContent): string {
  const details = JSON.stringify({ url: page.url, title: page.title, element: page.element, changes: page.changes });
  const reference = t('网页批注的页面信息（引用资料）：\n{0}\n截图中的红色笔迹是用户标记。', [details]);
  return page.note ? reference + '\n' + t('用户备注：{0}', [page.note]) : reference;
}
