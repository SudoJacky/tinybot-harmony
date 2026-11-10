import { children, elements, escapeXml, OFFICE_REL, PACKAGE_REL, part, relPath, saveXml, xml } from './package.mjs';
import { addSlideChart, CHART, slideChart, updateSlideChart } from './slide-charts.mjs';

export const PRESENTATION = 'http://schemas.openxmlformats.org/presentationml/2006/main';
export const DRAWING = 'http://schemas.openxmlformats.org/drawingml/2006/main';
export const SLIDE_WIDTH = 40 / 3;
export const SLIDE_HEIGHT = 7.5;
const EMU = 914400;
const THEME_SLOTS = { background: 'lt1', text: 'dk1', muted: 'dk2', accent: 'accent1', accent2: 'accent2' };
const THEME_COLORS = { background: 'FFFFFF', text: '173752', muted: '526579', accent: '207F78', accent2: 'DD7950' };
const SHAPES = new Set(['rect', 'roundRect', 'ellipse', 'triangle', 'diamond', 'hexagon', 'chevron', 'rightArrow', 'star5', 'line']);
const ALIGN = { left: 'l', center: 'ctr', right: 'r' };
const VERTICAL = { top: 't', middle: 'ctr', bottom: 'b' };

export function child(node, ns, name) {
  return node && children(node, ns, name)[0];
}

function finite(value, min, max, name) {
  if (!Number.isFinite(value) || value < min || value > max) throw new Error('Invalid slide ' + name + ': ' + value);
  return value;
}

function color(value) {
  if (typeof value !== 'string' || !/^#?[0-9a-f]{6}$/i.test(value)) throw new Error('Expected a six-digit slide color: ' + value);
  return value.replace(/^#/, '').toUpperCase();
}

function choice(value, choices, name) {
  if (!Object.hasOwn(choices, value)) throw new Error('Invalid slide ' + name + ': ' + value);
  return choices[value];
}

function paint(value) {
  if (value === 'none') return '<a:noFill/>';
  const shade = Object.hasOwn(THEME_SLOTS, value) ?
    '<a:schemeClr val="' + THEME_SLOTS[value] + '"/>' : '<a:srgbClr val="' + color(value) + '"/>';
  return '<a:solidFill>' + shade + '</a:solidFill>';
}

function fragment(document, source) {
  const wrapper = '<root xmlns:p="' + PRESENTATION + '" xmlns:a="' + DRAWING + '" xmlns:r="' + OFFICE_REL + '">' + source + '</root>';
  const parsed = xml({ 'fragment.xml': part(wrapper) }, 'fragment.xml');
  return document.importNode(parsed.documentElement.firstChild, true);
}

function setChild(parent, ns, name, source, before) {
  const previous = child(parent, ns, name);
  const node = fragment(parent.ownerDocument, source);
  if (previous) parent.replaceChild(node, previous);
  else parent.insertBefore(node, before || null);
  return node;
}

function font(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 100) throw new Error('Invalid slide font.');
  return escapeXml(value);
}

export function setDeckTheme(entries, theme) {
  if (theme === undefined) return;
  if (!theme || typeof theme !== 'object' || Array.isArray(theme) ||
    Object.keys(theme).some((key) => !Object.hasOwn(THEME_SLOTS, key) && key !== 'name' && key !== 'fontFace')) {
    throw new Error('Expected theme name, fontFace and theme colors.');
  }
  const path = 'ppt/theme/theme1.xml';
  const document = xml(entries, path);
  const root = document.documentElement;
  const scheme = elements(root, DRAWING, 'clrScheme')[0];
  if (theme.name !== undefined) {
    font(theme.name);
    root.setAttribute('name', theme.name);
    scheme.setAttribute('name', theme.name);
  }
  for (const [key, slot] of Object.entries(THEME_SLOTS)) {
    if (theme[key] === undefined) continue;
    const target = child(scheme, DRAWING, slot);
    const previous = children(target, DRAWING)[0];
    target.replaceChild(fragment(document, '<a:srgbClr val="' + color(theme[key]) + '"/>'), previous);
  }
  if (theme.fontFace !== undefined) {
    font(theme.fontFace);
    const fonts = elements(root, DRAWING, 'fontScheme')[0];
    for (const group of ['majorFont', 'minorFont']) {
      const target = child(fonts, DRAWING, group);
      for (const slot of ['latin', 'ea', 'cs']) child(target, DRAWING, slot)?.setAttribute('typeface', theme.fontFace);
    }
  }
  saveXml(entries, path, document);
}

export function deckTheme(entries) {
  const root = xml(entries, 'ppt/theme/theme1.xml').documentElement;
  const scheme = elements(root, DRAWING, 'clrScheme')[0];
  const result = { name: root.getAttribute('name'), fontFace: elements(root, DRAWING, 'latin')[1]?.getAttribute('typeface') };
  for (const [key, slot] of Object.entries(THEME_SLOTS)) {
    const node = child(scheme, DRAWING, slot);
    const value = child(node, DRAWING, 'srgbClr')?.getAttribute('val') || child(node, DRAWING, 'sysClr')?.getAttribute('lastClr');
    result[key] = value || THEME_COLORS[key];
  }
  return result;
}

function coordinates(item) {
  return {
    x: Math.round(finite(item.x, -SLIDE_WIDTH, 2 * SLIDE_WIDTH, 'x') * EMU),
    y: Math.round(finite(item.y, -SLIDE_HEIGHT, 2 * SLIDE_HEIGHT, 'y') * EMU),
    w: Math.round(finite(item.w, 0.001, 2 * SLIDE_WIDTH, 'w') * EMU),
    h: Math.round(finite(item.h, 0.001, 2 * SLIDE_HEIGHT, 'h') * EMU),
    rotate: Math.round(finite(item.rotate ?? 0, -360, 360, 'rotate') * 60000)
  };
}

function transform(item, prefix = 'a') {
  const box = coordinates(item);
  if (prefix === 'p' && box.rotate !== 0) throw new Error('Chart rotation is unsupported.');
  return '<' + prefix + ':xfrm' + (prefix === 'a' ? ' rot="' + box.rotate + '"' : '') + '><a:off x="' + box.x + '" y="' + box.y +
    '"/><a:ext cx="' + box.w + '" cy="' + box.h + '"/></' + prefix + ':xfrm>';
}

function readBox(transform) {
  const offset = child(transform, DRAWING, 'off');
  const size = child(transform, DRAWING, 'ext');
  return offset && size ? { x: Number(offset.getAttribute('x')) / EMU, y: Number(offset.getAttribute('y')) / EMU,
    w: Number(size.getAttribute('cx')) / EMU, h: Number(size.getAttribute('cy')) / EMU,
    rotate: Number(transform.getAttribute('rot')) / 60000 } : {};
}

function line(stroke, width) {
  return '<a:ln w="' + Math.round(finite(width ?? 1, 0, 30, 'strokeWidth') * 12700) + '">' + paint(stroke) + '</a:ln>';
}

function geometry(shape) {
  if (!SHAPES.has(shape)) throw new Error('Unsupported slide shape: ' + shape);
  return '<a:prstGeom prst="' + shape + '"><a:avLst/></a:prstGeom>';
}

function textBody(item) {
  if (typeof item.text !== 'string' || !item.text.trim() || item.text.length > 5000) throw new Error('Expected slide text (1–5000 characters).');
  const align = choice(item.align ?? 'left', ALIGN, 'alignment');
  const vertical = choice(item.verticalAlign ?? 'top', VERTICAL, 'vertical alignment');
  const size = Math.round(finite(item.fontSize ?? 24, 4, 300, 'fontSize') * 100);
  if ((item.bold !== undefined && typeof item.bold !== 'boolean') || (item.italic !== undefined && typeof item.italic !== 'boolean')) {
    throw new Error('Slide text bold and italic must be booleans.');
  }
  const face = item.fontFace ? font(item.fontFace) : '+mn-lt';
  const rPr = '<a:rPr sz="' + size + '" b="' + Number(!!item.bold) + '" i="' + Number(!!item.italic) + '">' +
    paint(item.color ?? 'text') + '<a:latin typeface="' + face + '"/><a:ea typeface="' +
    (item.fontFace ? face : '+mn-ea') + '"/><a:cs typeface="' + (item.fontFace ? face : '+mn-cs') + '"/></a:rPr>';
  const paragraphs = item.text.split(/\r\n|[\r\n]/).map((lineText) =>
    '<a:p><a:pPr algn="' + align + '"/><a:r>' + rPr + '<a:t xml:space="preserve">' + escapeXml(lineText) + '</a:t></a:r></a:p>');
  return '<p:txBody><a:bodyPr lIns="0" rIns="0" tIns="0" bIns="0" anchor="' + vertical + '"/><a:lstStyle/>' +
    paragraphs.join('') + '</p:txBody>';
}

function imageFormat(data) {
  if (!(data instanceof Uint8Array) || data.length < 12 || data.length > 12 * 1024 * 1024) {
    throw new Error('Expected PNG or JPEG image bytes up to 12 MiB.');
  }
  if ([137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => data[index] === byte)) return 'png';
  if (data[0] === 255 && data[1] === 216 && data[2] === 255 && data[data.length - 2] === 255 && data[data.length - 1] === 217) return 'jpeg';
  throw new Error('Only PNG and JPEG slide images are supported.');
}

function addImage(entries, path, links, data, elementId) {
  const extension = imageFormat(data);
  if (!/^\d+$/.test(String(elementId))) throw new Error('Invalid image element ID.');
  const owner = path.slice(0, path.indexOf('/slides/'));
  if (!owner) throw new Error('Invalid slide path.');
  const stem = path.slice(path.lastIndexOf('/') + 1, -4);
  const root = links.documentElement;
  let suffix = 1;
  const used = new Set(children(root, PACKAGE_REL, 'Relationship').map((link) => link.getAttribute('Id')));
  while (used.has('rIdTinybotImage' + suffix) || Object.hasOwn(entries, owner + '/media/' + stem + '-' + elementId + '-' + suffix + '.' + extension)) suffix++;
  const id = 'rIdTinybotImage' + suffix;
  const name = stem + '-' + elementId + '-' + suffix + '.' + extension;
  entries[owner + '/media/' + name] = data.slice();
  const link = links.createElementNS(PACKAGE_REL, 'Relationship');
  link.setAttribute('Id', id);
  link.setAttribute('Type', OFFICE_REL + '/image');
  link.setAttribute('Target', '../media/' + name);
  root.appendChild(link);
  return id;
}

export function renderSlideElements(document, slide, entries, path, links) {
  if (!slide || !Array.isArray(slide.elements) || slide.elements.length > 150) throw new Error('Expected up to 150 elements per slide.');
  const contents = elements(document, PRESENTATION, 'cSld')[0];
  const tree = child(contents, PRESENTATION, 'spTree');
  for (const item of children(tree, PRESENTATION, 'sp')) tree.removeChild(item);
  setChild(contents, PRESENTATION, 'bg', '<p:bg><p:bgPr>' + paint(slide.background ?? 'background') + '<a:effectLst/></p:bgPr></p:bg>', tree);
  const ids = new Set();
  slide.elements.forEach((item, index) => {
    if (!item || typeof item.id !== 'string' || !/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/.test(item.id) || ids.has(item.id)) {
      throw new Error('Each slide element needs a unique ID.');
    }
    ids.add(item.id);
    const id = index + 2;
    const description = item.alt === undefined ? '' : ' descr="' + escapeXml(item.alt) + '"';
    const identity = '<p:cNvPr id="' + id + '" name="' + item.id + '"' + description + '/>';
    if (item.type === 'chart') {
      const box = transform(item, 'p');
      const relation = addSlideChart(entries, path, links, id, item);
      tree.appendChild(fragment(document, '<p:graphicFrame><p:nvGraphicFramePr>' + identity +
        '<p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>' + box + '<a:graphic><a:graphicData uri="' + CHART + '">' +
        '<c:chart xmlns:c="' + CHART + '" r:id="' + relation + '"/></a:graphicData></a:graphic></p:graphicFrame>'));
      return;
    }
    const box = transform(item);
    if (item.type === 'image') {
      const relation = addImage(entries, path, links, item.data, id);
      tree.appendChild(fragment(document, '<p:pic><p:nvPicPr>' + identity + '<p:cNvPicPr/><p:nvPr/></p:nvPicPr>' +
        '<p:blipFill><a:blip r:embed="' + relation + '"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>' +
        '<p:spPr>' + box + geometry('rect') + '</p:spPr></p:pic>'));
      return;
    }
    if (item.type !== 'text' && item.type !== 'shape') throw new Error('Unsupported slide element type: ' + item.type);
    const shape = item.type === 'text' ? 'rect' : item.shape;
    const properties = box + geometry(shape) + paint(item.fill ?? 'none') +
      line(item.stroke ?? (shape === 'line' ? 'accent' : 'none'), item.strokeWidth);
    tree.appendChild(fragment(document, '<p:sp><p:nvSpPr>' + identity + '<p:cNvSpPr' +
      (item.type === 'text' ? ' txBox="1"' : '') + '/><p:nvPr/></p:nvSpPr><p:spPr>' + properties + '</p:spPr>' +
      (item.type === 'text' ? textBody(item) : '') + '</p:sp>'));
  });
}

export function slideElements(document) {
  const tree = elements(document, PRESENTATION, 'spTree')[0];
  return children(tree, PRESENTATION).filter((item) => ['sp', 'pic', 'graphicFrame'].includes(item.localName));
}

function identity(element) {
  return elements(element, PRESENTATION, 'cNvPr')[0];
}

function readPaint(parent) {
  if (child(parent, DRAWING, 'noFill')) return 'none';
  const solid = child(parent, DRAWING, 'solidFill');
  const scheme = child(solid, DRAWING, 'schemeClr')?.getAttribute('val');
  return child(solid, DRAWING, 'srgbClr')?.getAttribute('val') ||
    Object.keys(THEME_SLOTS).find((name) => THEME_SLOTS[name] === scheme);
}

export function inspectSlideElements(document, entries, path) {
  return slideElements(document).flatMap((element) => {
    const descriptor = identity(element);
    if (element.localName === 'graphicFrame') {
      const chart = slideChart(entries, path, element);
      if (!chart) return [];
      const { chartPath: _path, ...data } = chart;
      return [{ id: descriptor?.getAttribute('name'), type: 'chart', ...readBox(child(element, PRESENTATION, 'xfrm')), ...data }];
    }
    const properties = child(element, PRESENTATION, 'spPr');
    const shape = child(properties, DRAWING, 'prstGeom')?.getAttribute('prst');
    const transform = child(properties, DRAWING, 'xfrm');
    const text = child(element, PRESENTATION, 'txBody');
    const run = text && elements(text, DRAWING, 'rPr')[0];
    const stroke = child(properties, DRAWING, 'ln');
    return [{ id: descriptor?.getAttribute('name'), alt: descriptor?.getAttribute('descr') || undefined,
      type: element.localName === 'pic' ? 'image' : text ? 'text' : 'shape', ...readBox(transform), shape,
      fill: readPaint(properties), stroke: readPaint(stroke),
      strokeWidth: stroke?.hasAttribute('w') ? Number(stroke.getAttribute('w')) / 12700 : undefined,
      fontSize: run?.hasAttribute('sz') ? Number(run.getAttribute('sz')) / 100 : undefined, color: readPaint(run),
      text: text ? children(text, DRAWING, 'p').map((p) => elements(p, DRAWING, 't').map((node) => node.textContent).join('')).join('\n') : undefined }];
  });
}

function replacePaint(parent, value) {
  const previous = children(parent, DRAWING).find((node) => ['noFill', 'solidFill', 'gradFill', 'blipFill', 'pattFill', 'grpFill'].includes(node.localName));
  const node = fragment(parent.ownerDocument, paint(value));
  if (previous) parent.replaceChild(node, previous);
  else {
    const afterFill = parent.localName === 'rPr' ? children(parent, DRAWING).find((item) => item.localName !== 'ln') :
      children(parent, DRAWING).find((item) => ['ln', 'effectLst', 'effectDag', 'scene3d', 'sp3d', 'extLst'].includes(item.localName));
    parent.insertBefore(node, afterFill || null);
  }
}

export function updateSlideElement(document, entries, path, links, name, changes) {
  const matches = slideElements(document).filter((element) => identity(element)?.getAttribute('name') === name);
  if (matches.length !== 1) throw new Error('Expected one slide element with ID: ' + name);
  const item = matches[0];
  const properties = child(item, PRESENTATION, 'spPr');
  const text = child(item, PRESENTATION, 'txBody');
  const image = item.localName === 'pic';
  if (!changes || typeof changes !== 'object' || Array.isArray(changes) || !Object.keys(changes).length) throw new Error('Expected element changes.');
  const geometryKeys = ['x', 'y', 'w', 'h', 'rotate'];
  if (item.localName === 'graphicFrame') {
    const fields = ['chart', 'categories', 'series', 'title', 'legend', 'colors'];
    if (Object.keys(changes).some((key) => !geometryKeys.includes(key) && !fields.includes(key))) throw new Error('Invalid chart change for ' + name);
    if (!slideChart(entries, path, item)) throw new Error('Unsupported chart element: ' + name);
    if (geometryKeys.some((key) => Object.hasOwn(changes, key))) {
      const previous = readBox(child(item, PRESENTATION, 'xfrm'));
      setChild(item, PRESENTATION, 'xfrm', transform({ ...previous, ...changes }, 'p'), child(item, DRAWING, 'graphic'));
    }
    if (fields.some((key) => Object.hasOwn(changes, key))) updateSlideChart(entries, path, item, changes);
    return;
  }
  const textKeys = ['text', 'fontSize', 'fontFace', 'color', 'bold', 'italic', 'align', 'verticalAlign'];
  const appearance = image ? ['data'] : text ? ['fill', 'stroke', 'strokeWidth', ...textKeys] : ['fill', 'stroke', 'strokeWidth', 'shape'];
  if (Object.keys(changes).some((key) => !geometryKeys.includes(key) && !appearance.includes(key))) throw new Error('Invalid change for ' + name);
  if (geometryKeys.some((key) => Object.hasOwn(changes, key))) {
    const previous = readBox(child(properties, DRAWING, 'xfrm'));
    setChild(properties, DRAWING, 'xfrm', transform({ ...previous, ...changes }), properties.firstChild);
  }
  if (Object.hasOwn(changes, 'shape')) setChild(properties, DRAWING, 'prstGeom', geometry(changes.shape), child(properties, DRAWING, 'ln'));
  if (Object.hasOwn(changes, 'fill')) replacePaint(properties, changes.fill);
  if (Object.hasOwn(changes, 'stroke') || Object.hasOwn(changes, 'strokeWidth')) {
    const stroke = child(properties, DRAWING, 'ln') || setChild(properties, DRAWING, 'ln', line('none'));
    if (Object.hasOwn(changes, 'stroke')) replacePaint(stroke, changes.stroke);
    if (Object.hasOwn(changes, 'strokeWidth')) stroke.setAttribute('w', String(Math.round(finite(changes.strokeWidth, 0, 30, 'strokeWidth') * 12700)));
  }
  if (Object.hasOwn(changes, 'data')) {
    const relation = addImage(entries, path, links, changes.data, identity(item).getAttribute('id'));
    const blip = child(child(item, PRESENTATION, 'blipFill'), DRAWING, 'blip');
    blip.setAttributeNS(OFFICE_REL, 'r:embed', relation);
  }
  if (!text || !textKeys.some((key) => Object.hasOwn(changes, key))) return;
  const paragraphs = children(text, DRAWING, 'p');
  if (Object.hasOwn(changes, 'text')) {
    if (typeof changes.text !== 'string' || !changes.text.trim() || changes.text.length > 5000) throw new Error('Expected slide text (1–5000 characters).');
    const base = paragraphs[0];
    const template = child(base, DRAWING, 'r');
    if (!template) throw new Error('Text element has no editable run.');
    for (const previous of paragraphs) text.removeChild(previous);
    for (const lineText of changes.text.split(/\r\n|[\r\n]/)) {
      const paragraph = base.cloneNode(false);
      const properties = child(base, DRAWING, 'pPr');
      if (properties) paragraph.appendChild(properties.cloneNode(true));
      const run = template.cloneNode(true);
      child(run, DRAWING, 't').textContent = escapeFreeText(lineText);
      paragraph.appendChild(run);
      text.appendChild(paragraph);
    }
  }
  if (Object.hasOwn(changes, 'verticalAlign')) child(text, DRAWING, 'bodyPr').setAttribute('anchor', choice(changes.verticalAlign, VERTICAL, 'vertical alignment'));
  for (const paragraph of children(text, DRAWING, 'p')) {
    if (Object.hasOwn(changes, 'align')) {
      const format = child(paragraph, DRAWING, 'pPr') || setChild(paragraph, DRAWING, 'pPr', '<a:pPr/>', paragraph.firstChild);
      format.setAttribute('algn', choice(changes.align, ALIGN, 'alignment'));
    }
    for (const run of children(paragraph, DRAWING, 'r')) {
      const format = child(run, DRAWING, 'rPr') || setChild(run, DRAWING, 'rPr', '<a:rPr/>', run.firstChild);
      if (Object.hasOwn(changes, 'fontSize')) format.setAttribute('sz', String(Math.round(finite(changes.fontSize, 4, 300, 'fontSize') * 100)));
      if (Object.hasOwn(changes, 'color')) replacePaint(format, changes.color);
      if (Object.hasOwn(changes, 'fontFace')) {
        const face = font(changes.fontFace);
        for (const slot of ['latin', 'ea', 'cs']) setChild(format, DRAWING, slot, '<a:' + slot + ' typeface="' + face + '"/>');
      }
      for (const [key, attr] of [['bold', 'b'], ['italic', 'i']]) {
        if (!Object.hasOwn(changes, key)) continue;
        if (typeof changes[key] !== 'boolean') throw new Error('Slide text ' + key + ' must be boolean.');
        format.setAttribute(attr, String(Number(changes[key])));
      }
    }
  }
}

function escapeFreeText(text) {
  escapeXml(text);
  return text;
}

export function slideRelationships(entries, path) {
  const target = relPath(path);
  if (Object.hasOwn(entries, target)) return xml(entries, target);
  return xml({ 'rels.xml': part('<Relationships xmlns="' + PACKAGE_REL + '"/>') }, 'rels.xml');
}
