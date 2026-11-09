import { strFromU8, strToU8, unzipSync, zipSync } from 'fflate';
import { DOMParser, XMLSerializer } from '@xmldom/xmldom';

export const OFFICE_REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
export const PACKAGE_REL = 'http://schemas.openxmlformats.org/package/2006/relationships';
export const CONTENT_TYPES = 'http://schemas.openxmlformats.org/package/2006/content-types';
const MIME = {
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml',
};

export function text(bytes) {
  if (!(bytes instanceof Uint8Array)) throw new Error('Expected file bytes from files[path].');
  return strFromU8(bytes).replace(/^\uFEFF/, '');
}

export function xmlText(value) {
  if (typeof value !== 'string' || /[\x00-\x08\x0b\x0c\x0e-\x1f\uFFFE\uFFFF]/u.test(value) || !value.isWellFormed()) {
    throw new Error('Expected text containing valid XML characters.');
  }
  return value;
}

export function escapeXml(value) {
  return xmlText(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

export function part(value) {
  return strToU8('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + value);
}

export function contentTypes(overrides) {
  return part(`<Types xmlns="${CONTENT_TYPES}"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
    overrides.map(([path, mime]) => `<Override PartName="/${path}" ContentType="${mime}"/>`).join('') + '</Types>');
}

export function relationships(links) {
  return part(`<Relationships xmlns="${PACKAGE_REL}">` + links.map(([id, type, target]) =>
    `<Relationship Id="${id}" Type="${OFFICE_REL}/${type}" Target="${target}"/>`).join('') + '</Relationships>');
}

export function newPackage(format, main, entries, overrides = []) {
  return zip({
    '[Content_Types].xml': contentTypes([[main, MIME[format]], ...overrides]),
    '_rels/.rels': relationships([['rId1', 'officeDocument', main]]),
    ...entries,
  });
}

export function zip(entries) {
  return zipSync(entries, { level: 3, mtime: new Date(2020, 0, 1) });
}

export function unzip(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length < 22 || bytes[0] !== 80 || bytes[1] !== 75 || bytes[2] !== 3 || bytes[3] !== 4) {
    throw new Error('Expected an unencrypted Office ZIP file.');
  }
  let total = 0;
  const names = new Set();
  return unzipSync(bytes, { filter: ({ name, originalSize, size, compression }) => {
    if (names.has(name) || names.size >= 2048 || !name || /^[\/\\]|\\|[\x00-\x1f]/.test(name) ||
        name.split('/').some((item) => item === '.' || item === '..') || Object.hasOwn(Object.prototype, name) ||
        ![0, 8].includes(compression) || (compression === 0 && size !== originalSize)) {
      throw new Error('Unsupported Office ZIP entry: ' + name);
    }
    names.add(name);
    total += originalSize;
    if (total > 64 * 1024 * 1024) throw new Error('Expanded Office file exceeds 64 MiB.');
    return !name.endsWith('/');
  } });
}

export function xml(entries, path) {
  if (!Object.hasOwn(entries, path)) throw new Error('Office package is missing ' + path + '.');
  const source = text(entries[path]);
  if (/<!DOCTYPE\b/i.test(source)) throw new Error('Office XML with a DTD is unsupported.');
  return new DOMParser({ onError: (_level, message) => { throw new Error(path + ': ' + message); } })
    .parseFromString(source, 'application/xml');
}

export function saveXml(entries, path, document) {
  entries[path] = strToU8(new XMLSerializer().serializeToString(document));
}

export function elements(node, namespace, name) {
  return Array.from(node.getElementsByTagNameNS(namespace, name));
}

export function children(node, namespace, name) {
  return Array.from(node.childNodes).filter((child) => child.nodeType === 1 &&
    child.namespaceURI === namespace && (!name || child.localName === name));
}

export function root(document, namespace, name) {
  if (document.documentElement.namespaceURI !== namespace || document.documentElement.localName !== name) {
    throw new Error('Expected ' + name + ' XML in the supported Office namespace.');
  }
  return document.documentElement;
}

export function relPath(path) {
  const slash = path.lastIndexOf('/') + 1;
  return path.slice(0, slash) + '_rels/' + path.slice(slash) + '.rels';
}

export function targetPath(source, relationship) {
  const target = relationship.getAttribute('Target');
  if (relationship.getAttribute('TargetMode') === 'External' || !target || /[:\\?#]/.test(target)) {
    throw new Error('Expected an internal Office relationship.');
  }
  const parts = (target.startsWith('/') ? [] : source.split('/').slice(0, -1));
  for (const segment of target.replace(/^\//, '').split('/')) {
    if (segment === '..' && parts.length) parts.pop();
    else if (!segment || segment === '..' || segment === '.') throw new Error('Invalid Office relationship path.');
    else parts.push(segment);
  }
  return parts.join('/');
}

export function related(entries, source, type, id) {
  const document = xml(entries, relPath(source));
  const links = elements(document, PACKAGE_REL, 'Relationship').filter((item) =>
    item.getAttribute('Type') === OFFICE_REL + '/' + type && (id === undefined || item.getAttribute('Id') === id));
  if (links.length !== 1) throw new Error('Missing or ambiguous Office relationship: ' + type);
  return targetPath(source, links[0]);
}

export function openPackage(bytes, format) {
  const entries = unzip(bytes);
  const main = related(entries, '', 'officeDocument');
  const types = elements(xml(entries, '[Content_Types].xml'), CONTENT_TYPES, 'Override');
  if (!Object.hasOwn(entries, main) ||
      !types.some((type) => type.getAttribute('PartName') === '/' + main && type.getAttribute('ContentType') === MIME[format])) {
    throw new Error('The file does not match the .' + format + ' format.');
  }
  return { entries, main };
}

export function verify(bytes, format) {
  const { entries, main } = openPackage(bytes, format);
  const expected = {
    docx: ['http://schemas.openxmlformats.org/wordprocessingml/2006/main', 'document'],
    xlsx: ['http://schemas.openxmlformats.org/spreadsheetml/2006/main', 'workbook'],
    pptx: ['http://schemas.openxmlformats.org/presentationml/2006/main', 'presentation'],
  };
  root(xml(entries, main), ...expected[format]);
}
