import { CONTENT_TYPES, OFFICE_REL, PACKAGE_REL, children, elements, escapeXml, newPackage,
  openPackage, part, related, relPath, relationships, root, saveXml, targetPath, xml, xmlText, zip } from './package.mjs';

const NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const SHEET_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml';
const MAX_ROW = 1048576;
const MAX_COLUMN = 16384;

function address(row, column) {
  let letters = '';
  for (let index = column; index > 0; index = Math.floor((index - 1) / 26)) {
    letters = String.fromCharCode(65 + (index - 1) % 26) + letters;
  }
  return letters + row;
}

function coordinates(value) {
  const match = typeof value === 'string' && /^([A-Z]{1,3})([1-9]\d{0,6})$/i.exec(value);
  if (!match) throw new Error('Expected an Excel cell address like B2.');
  const row = Number(match[2]);
  const column = Array.from(match[1].toUpperCase()).reduce((result, letter) => result * 26 + letter.charCodeAt(0) - 64, 0);
  if (row > MAX_ROW || column > MAX_COLUMN) throw new Error('Cell is outside the Excel worksheet: ' + value);
  return { row, column };
}

function cellValue(value) {
  if (value === null) return { type: '', child: '', text: '' };
  if (typeof value === 'string') {
    if (value.length > 32767) throw new Error('Excel cell text exceeds 32,767 characters.');
    return { type: 'inlineStr', child: 'is', text: xmlText(value).replace(/_(?=x[0-9a-f]{4}_)/gi, '_x005F_') };
  }
  if (typeof value === 'boolean') return { type: 'b', child: 'v', text: value ? '1' : '0' };
  if (typeof value === 'number' && Number.isFinite(value)) return { type: 'n', child: 'v', text: String(value) };
  if (value && typeof value === 'object' && Object.keys(value).length === 1 &&
      typeof value.formula === 'string' && value.formula.replace(/^=/, '').trim() && value.formula.length <= 8192) {
    return { type: '', child: 'f', text: xmlText(value.formula.replace(/^=/, '')) };
  }
  throw new Error('Expected a string, finite number, boolean, null, or {formula:"A1+1"}.');
}

function cellXml(value, ref) {
  const { type, child, text } = cellValue(value);
  if (!child) return '';
  const data = child === 'is' ? '<t xml:space="preserve">' + escapeXml(text) + '</t>' : escapeXml(text);
  return `<c r="${ref}"${type ? ' t="' + type + '"' : ''}><${child}>${data}</${child}></c>`;
}

export function xlsx(sheets) {
  if (!Array.isArray(sheets) || !sheets.length || sheets.length > 100) throw new Error('Expected 1–100 worksheets.');
  const names = new Set();
  const entries = {};
  const overrides = [];
  const links = [];
  const sheetXml = sheets.map(({ name, rows }, index) => {
    if (typeof name !== 'string' || !name.trim() || name.length > 31 || /[\[\]*?/\\:\x00-\x1f]/.test(name) ||
        name.startsWith("'") || name.endsWith("'") || names.has(name.toLowerCase()) || name.toLowerCase() === 'history') {
      throw new Error('Invalid or duplicate Excel worksheet name: ' + name);
    }
    if (!Array.isArray(rows) || rows.length > MAX_ROW) throw new Error('Expected a worksheet rows array.');
    names.add(name.toLowerCase());
    const id = index + 1;
    const path = 'worksheets/sheet' + id + '.xml';
    links.push(['rId' + id, 'worksheet', path]);
    overrides.push(['xl/' + path, SHEET_MIME]);
    const rowsXml = rows.map((row, rowIndex) => {
      if (!Array.isArray(row) || row.length > MAX_COLUMN) throw new Error('Expected an array of cells for each Excel row.');
      const number = rowIndex + 1;
      return `<row r="${number}">${row.map((value, column) => cellXml(value, address(number, column + 1))).join('')}</row>`;
    }).join('');
    entries['xl/' + path] = part(`<worksheet xmlns="${NS}"><sheetData>${rowsXml}</sheetData></worksheet>`);
    return `<sheet name="${escapeXml(name)}" sheetId="${id}" r:id="rId${id}"/>`;
  }).join('');
  entries['xl/workbook.xml'] = part(`<workbook xmlns="${NS}" xmlns:r="${OFFICE_REL}"><sheets>${sheetXml}</sheets><calcPr fullCalcOnLoad="1"/></workbook>`);
  entries['xl/_rels/workbook.xml.rels'] = relationships(links);
  return newPackage('xlsx', 'xl/workbook.xml', entries, overrides);
}

function rangeContains(ref, row, column) {
  const [first, last = first] = ref.split(':');
  const start = coordinates(first);
  const end = coordinates(last);
  return row >= start.row && row <= end.row && column >= start.column && column <= end.column;
}

function add(parent, name, before = null) {
  const node = parent.ownerDocument.createElementNS(NS, parent.prefix ? parent.prefix + ':' + name : name);
  parent.insertBefore(node, before);
  return node;
}

function extendDimension(worksheet, row, column) {
  const dimension = children(worksheet, NS, 'dimension')[0];
  if (!dimension) return;
  const [first, last = first] = dimension.getAttribute('ref').split(':');
  const start = coordinates(first);
  const end = coordinates(last);
  const from = address(Math.min(row, start.row), Math.min(column, start.column));
  const to = address(Math.max(row, end.row), Math.max(column, end.column));
  dimension.setAttribute('ref', from === to ? from : from + ':' + to);
}

function setCell(worksheet, ref, value) {
  const { row, column } = coordinates(ref);
  const normalized = address(row, column);
  const data = children(worksheet, NS, 'sheetData')[0];
  if (!data) throw new Error('Worksheet is missing its cell data.');
  for (const merge of elements(worksheet, NS, 'mergeCell')) {
    const range = merge.getAttribute('ref');
    if (normalized !== range.split(':')[0] && rangeContains(range, row, column)) {
      throw new Error('Edit the upper-left cell of merged range ' + range + '.');
    }
  }
  for (const formula of elements(data, NS, 'f')) {
    const range = formula.getAttribute('ref');
    if (range && rangeContains(range, row, column)) throw new Error('Cannot edit part of formula range ' + range + '.');
  }
  const rows = children(data, NS, 'row');
  let line = rows.find((candidate) => Number(candidate.getAttribute('r')) === row);
  if (!line && value === null) return;
  if (!line) {
    line = add(data, 'row', rows.find((candidate) => Number(candidate.getAttribute('r')) > row));
    line.setAttribute('r', String(row));
  }
  const cells = children(line, NS, 'c');
  let cell = cells.find((candidate) => candidate.getAttribute('r') === normalized);
  if (!cell && value === null) return;
  if (!cell) {
    cell = add(line, 'c', cells.find((candidate) => coordinates(candidate.getAttribute('r')).column > column) ||
      children(line, NS, 'extLst')[0]);
    cell.setAttribute('r', normalized);
    line.removeAttribute('spans');
  }
  const old = children(cell, NS, 'f')[0];
  if ((old?.getAttribute('t') && old.getAttribute('t') !== 'normal') || cell.hasAttribute('cm') || cell.hasAttribute('vm')) {
    throw new Error('Cannot replace a cell with shared or array formulas or cell metadata: ' + normalized);
  }
  const spec = cellValue(value);
  for (const child of children(cell, NS)) {
    if (['f', 'v', 'is'].includes(child.localName)) cell.removeChild(child);
  }
  if (spec.type) cell.setAttribute('t', spec.type);
  else cell.removeAttribute('t');
  if (spec.child) {
    const node = add(cell, spec.child, children(cell, NS, 'extLst')[0]);
    if (spec.child === 'is') {
      const text = add(node, 't');
      text.setAttributeNS('http://www.w3.org/XML/1998/namespace', 'xml:space', 'preserve');
      text.textContent = spec.text;
    } else node.textContent = spec.text;
    extendDimension(worksheet, row, column);
  }
}

function recalculate(entries, main, workbook) {
  let calculation = children(workbook, NS, 'calcPr')[0];
  if (!calculation) {
    const afterCalcPr = ['oleSize', 'customWorkbookViews', 'pivotCaches', 'smartTagPr', 'smartTagTypes',
      'webPublishing', 'fileRecoveryPr', 'webPublishObjects', 'extLst'];
    calculation = add(workbook, 'calcPr', children(workbook, NS).find((node) => afterCalcPr.includes(node.localName)));
  }
  calculation.setAttribute('fullCalcOnLoad', '1');
  const relationshipsPath = relPath(main);
  const links = xml(entries, relationshipsPath);
  const chain = elements(links, PACKAGE_REL, 'Relationship').find((item) => item.getAttribute('Type') === OFFICE_REL + '/calcChain');
  if (chain) {
    const path = targetPath(main, chain);
    delete entries[path];
    chain.parentNode.removeChild(chain);
    saveXml(entries, relationshipsPath, links);
    const types = xml(entries, '[Content_Types].xml');
    const override = elements(types, CONTENT_TYPES, 'Override').find((item) => item.getAttribute('PartName') === '/' + path);
    if (override) override.parentNode.removeChild(override);
    saveXml(entries, '[Content_Types].xml', types);
  }
}

export function editXlsx(bytes, edits) {
  if (!Array.isArray(edits) || !edits.length) throw new Error('Expected at least one Excel cell edit.');
  const { entries, main } = openPackage(bytes, 'xlsx');
  const document = xml(entries, main);
  const workbook = root(document, NS, 'workbook');
  const tabs = elements(workbook, NS, 'sheet');
  const sheets = new Map();
  for (const { sheet, cell, value } of edits) {
    const match = tabs.find((item) => item.getAttribute('name') === sheet);
    if (!match) throw new Error('Worksheet not found: ' + sheet + '. Available sheets: ' + tabs.map((item) => item.getAttribute('name')).join(', '));
    const path = related(entries, main, 'worksheet', match.getAttributeNS(OFFICE_REL, 'id'));
    if (!sheets.has(path)) sheets.set(path, xml(entries, path));
    setCell(root(sheets.get(path), NS, 'worksheet'), cell, value);
  }
  for (const [path, sheet] of sheets) saveXml(entries, path, sheet);
  recalculate(entries, main, workbook);
  saveXml(entries, main, document);
  return zip(entries);
}
