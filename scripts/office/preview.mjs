import { children, elements, OFFICE_REL, openPackage, related, relPath, root, xml } from './package.mjs';
import { deckTheme } from './slide-elements.mjs';
import { slideChart } from './slide-charts.mjs';

const WORD = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const SHEET = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const SLIDE = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const DRAW = 'http://schemas.openxmlformats.org/drawingml/2006/main';

function first(node, ns, name) {
  return node && children(node, ns, name)[0];
}

function value(node, ns, name) {
  return node?.getAttributeNS(ns, name) || '';
}

function rgb(node, attr = 'val') {
  const color = node?.getAttribute(attr)?.slice(-6);
  return /^[\da-f]{6}$/i.test(color) ? '#' + color : undefined;
}

function image(entries, source, id) {
  if (!id) return undefined;
  const path = related(entries, source, 'image', id);
  const extension = path.split('.').pop().toLowerCase();
  const format = { png: 'png', jpg: 'jpeg', jpeg: 'jpeg', gif: 'gif', webp: 'webp', bmp: 'bmp' }[extension];
  if (!format || !entries[path]) throw new Error('Unsupported embedded image: ' + path);
  return URL.createObjectURL(new Blob([entries[path]], { type: 'image/' + format }));
}

function word(bytes) {
  const { entries, main } = openPackage(bytes, 'docx');
  const body = first(root(xml(entries, main), WORD, 'document'), WORD, 'body');
  if (!body) throw new Error('Word document has no body.');
  let paragraph = 0;
  function blocks(container) {
    return children(container, WORD).flatMap((node) => {
      if (node.localName === 'tbl') {
        return [{ rows: children(node, WORD, 'tr').map((row) => children(row, WORD, 'tc').map(blocks)) }];
      }
      if (node.localName !== 'p') return [];
      const style = value(first(first(node, WORD, 'pPr'), WORD, 'pStyle'), WORD, 'val');
      const level = /^heading\s*([1-6])$/i.exec(style)?.[1];
      const runs = elements(node, WORD, 'r').map((run) => {
        const properties = first(run, WORD, 'rPr');
        const fragments = children(run, WORD).flatMap((part) => {
          if (part.localName === 't') return [{ text: part.textContent }];
          if (part.localName === 'tab' || part.localName === 'br') return [{ text: part.localName === 'br' ? '\n' : '\t' }];
          if (part.localName !== 'drawing') return [];
          return elements(part, DRAW, 'blip').map((blip) => ({ image: image(entries, main, value(blip, OFFICE_REL, 'embed')) }));
        });
        return { fragments, bold: !!first(properties, WORD, 'b'), italic: !!first(properties, WORD, 'i'),
          color: rgb(first(properties, WORD, 'color'), 'w:val'), size: Number(value(first(properties, WORD, 'sz'), WORD, 'val')) / 2 };
      });
      return [{ paragraph: ++paragraph, level, runs }];
    });
  }
  return blocks(body);
}

function workbook(bytes) {
  const { entries, main } = openPackage(bytes, 'xlsx');
  const book = root(xml(entries, main), SHEET, 'workbook');
  const links = xml(entries, relPath(main)).documentElement;
  const has = (name) => Array.from(links.childNodes).some((node) => node.nodeType === 1 &&
    node.getAttribute('Type') === OFFICE_REL + '/' + name);
  const part = (name) => has(name) ? xml(entries, related(entries, main, name)).documentElement : undefined;
  const text = (node) => elements(node, SHEET, 't').map((item) => item.textContent).join('');
  const strings = part('sharedStrings');
  const shared = strings ? children(strings, SHEET, 'si').map(text) : [];
  const styles = part('styles');
  const list = (name) => {
    const node = first(styles, SHEET, name);
    return node ? children(node, SHEET) : [];
  };
  const fonts = list('fonts').map((node) => ({
    bold: !!first(node, SHEET, 'b'), color: rgb(first(node, SHEET, 'color'), 'rgb')
  }));
  const fills = list('fills').map((node) => rgb(first(first(node, SHEET, 'patternFill'), SHEET, 'fgColor'), 'rgb'));
  const cellStyles = list('cellXfs').map((node) => ({
    ...fonts[Number(node.getAttribute('fontId'))], background: fills[Number(node.getAttribute('fillId'))]
  }));
  return children(first(book, SHEET, 'sheets'), SHEET, 'sheet').map((item) => {
    const path = related(entries, main, 'worksheet', value(item, OFFICE_REL, 'id'));
    const sheet = root(xml(entries, path), SHEET, 'worksheet');
    const cells = new Map();
    let rows = 1;
    let columns = 1;
    for (const cell of elements(first(sheet, SHEET, 'sheetData'), SHEET, 'c')) {
      const address = cell.getAttribute('r');
      const match = /^([A-Z]{1,3})([1-9]\d{0,6})$/.exec(address);
      if (!match) throw new Error('Invalid cell address: ' + address);
      rows = Math.max(rows, Number(match[2]));
      columns = Math.max(columns, [...match[1]].reduce((result, letter) => result * 26 + letter.charCodeAt(0) - 64, 0));
      const type = cell.getAttribute('t');
      const raw = first(cell, SHEET, 'v')?.textContent;
      const formula = first(cell, SHEET, 'f')?.textContent;
      const result = type === 's' ? shared[Number(raw)] : type === 'inlineStr' ? text(cell) :
        type === 'b' ? (raw === '1' ? 'TRUE' : 'FALSE') : raw;
      cells.set(address, { text: result ?? (formula ? '=' + formula : ''), formula, style: cellStyles[Number(cell.getAttribute('s'))] });
    }
    return { name: item.getAttribute('name'), cells, rows, columns };
  });
}

function presentation(bytes) {
  const { entries, main } = openPackage(bytes, 'pptx');
  const deck = root(xml(entries, main), SLIDE, 'presentation');
  const size = first(deck, SLIDE, 'sldSz');
  const width = Number(size?.getAttribute('cx'));
  const height = Number(size?.getAttribute('cy'));
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) throw new Error('Invalid slide dimensions.');
  const theme = Object.hasOwn(entries, 'ppt/theme/theme1.xml') ? deckTheme(entries) : undefined;
  function paint(parent) {
    const solid = first(parent, DRAW, 'solidFill');
    const direct = rgb(first(solid, DRAW, 'srgbClr'));
    if (direct) return direct;
    const slot = first(solid, DRAW, 'schemeClr')?.getAttribute('val');
    const names = { lt1: 'background', bg1: 'background', dk1: 'text', tx1: 'text', dk2: 'muted', tx2: 'muted', accent1: 'accent', accent2: 'accent2' };
    return slot && theme?.[names[slot]] ? '#' + theme[names[slot]] : undefined;
  }
  const slides = children(first(deck, SLIDE, 'sldIdLst'), SLIDE, 'sldId').map((item) => {
    const path = related(entries, main, 'slide', value(item, OFFICE_REL, 'id'));
    const slide = root(xml(entries, path), SLIDE, 'sld');
    const contents = first(slide, SLIDE, 'cSld');
    const background = paint(first(first(contents, SLIDE, 'bg'), SLIDE, 'bgPr'));
    const shapes = children(first(contents, SLIDE, 'spTree'), SLIDE).flatMap((shape) => {
      if (!['sp', 'pic', 'graphicFrame'].includes(shape.localName)) return [];
      const chart = shape.localName === 'graphicFrame' ? slideChart(entries, path, shape) : undefined;
      if (shape.localName === 'graphicFrame' && !chart) return [];
      const properties = first(shape, SLIDE, 'spPr');
      const transform = chart ? first(shape, SLIDE, 'xfrm') : first(properties, DRAW, 'xfrm');
      const offset = first(transform, DRAW, 'off');
      const extent = first(transform, DRAW, 'ext');
      if (!offset || !extent) return [];
      const coordinates = {
        x: Number(offset.getAttribute('x')) / width, y: Number(offset.getAttribute('y')) / height,
        w: Number(extent.getAttribute('cx')) / width, h: Number(extent.getAttribute('cy')) / height,
        rotation: Number(transform.getAttribute('rot')) / 60000
      };
      const textBody = first(shape, SLIDE, 'txBody');
      const paragraphs = textBody ? children(textBody, DRAW, 'p').map((paragraph) => {
        const properties = first(paragraph, DRAW, 'pPr');
        const runs = children(paragraph, DRAW, 'r').map((run) => {
          const format = first(run, DRAW, 'rPr');
          const font = first(format, DRAW, 'latin')?.getAttribute('typeface');
          return { text: first(run, DRAW, 't')?.textContent || '', size: Number(format?.getAttribute('sz')) / 100 || 18,
            color: paint(format), font: font?.startsWith('+') ? theme?.fontFace : font,
            bold: format?.getAttribute('b') === '1', italic: format?.getAttribute('i') === '1' };
        });
        return { runs, bullet: !!first(properties, DRAW, 'buChar'), align: properties?.getAttribute('algn') };
      }) : [];
      const blip = first(first(shape, SLIDE, 'blipFill'), DRAW, 'blip');
      const identity = elements(shape, SLIDE, 'cNvPr')[0];
      const stroke = first(properties, DRAW, 'ln');
      return [{ ...coordinates, paragraphs, chart, image: image(entries, path, value(blip, OFFICE_REL, 'embed')),
        label: identity?.getAttribute('name'), id: identity?.getAttribute('id'),
        alt: identity?.getAttribute('descr'), preset: first(properties, DRAW, 'prstGeom')?.getAttribute('prst'),
        verticalAlign: first(textBody, DRAW, 'bodyPr')?.getAttribute('anchor'),
        background: paint(properties), stroke: paint(stroke), strokeWidth: Number(stroke?.getAttribute('w') || 12700) }];
    });
    return { shapes, background };
  });
  return { width, height, slides, theme };
}

export function readOfficePreview(bytes, format) {
  if (format === 'docx') return word(bytes);
  if (format === 'xlsx') return workbook(bytes);
  if (format === 'pptx') return presentation(bytes);
  throw new Error('Unsupported Office preview format: ' + format);
}
