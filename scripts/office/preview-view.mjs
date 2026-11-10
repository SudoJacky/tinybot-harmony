import { readOfficePreview } from './preview.mjs';

const toolbar = document.getElementById('toolbar');
const viewport = document.getElementById('viewport');
const form = document.getElementById('comment');
const note = form.querySelector('textarea');
const selectionAction = document.getElementById('text-action');
const modeButton = document.getElementById('annotate');
let labels;
let format;
let data;
let active = 0;
let rowStart = 1;
let colStart = 1;
let sequence = 0;
let mode = false;
let pending;
let marks = [];
let loaded = [];
let cellStart;
let selectionTimer;
let submitting = false;
let submission;

function element(tag, text, parent, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  parent?.append(node);
  return node;
}

function button(text, parent, action) {
  const node = element('button', text, parent);
  node.type = 'button';
  node.onclick = action;
  return node;
}

function report(type, detail) {
  document.title = 'office:' + JSON.stringify({ type, sequence: ++sequence, ...detail });
}

function position(node, x, y) {
  node.style.left = Math.max(8, Math.min(x, window.innerWidth - node.offsetWidth - 8)) + 'px';
  node.style.top = Math.max(8, Math.min(y, window.innerHeight - node.offsetHeight - 8)) + 'px';
}

function clearTarget() {
  if (submitting) return;
  form.hidden = true;
  selectionAction.hidden = true;
  pending = undefined;
  cellStart = undefined;
}

function openComment(target, x, y) {
  pending = target;
  selectionAction.hidden = true;
  form.hidden = false;
  note.value = '';
  position(form, x, y);
  note.focus({ preventScroll: true });
}

form.addEventListener('submit', (event) => {
  event.preventDefault();
  if (!pending || !note.value.trim() || submitting) return;
  submitting = true;
  form.querySelector('button[type=submit]').disabled = true;
  submission = { target: pending, comment: note.value };
  report('annotation', {});
});
window.getOfficeAnnotation = () => JSON.stringify(submission);
window.ackOfficeAnnotation = (saved) => {
  submission = undefined;
  submitting = false;
  form.querySelector('button[type=submit]').disabled = false;
  if (saved) clearTarget();
};
form.querySelector('button[type=button]').onclick = clearTarget;
form.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') clearTarget();
});
modeButton.onclick = () => {
  mode = !mode;
  clearTarget();
  modeButton.setAttribute('aria-pressed', String(mode));
  viewport.classList.toggle('annotating', mode);
};

function markers() {
  for (const node of viewport.querySelectorAll('.pin')) node.remove();
  for (const mark of marks) {
    const key = mark.location.split(' · ')[0];
    const location = format === 'xlsx' ? key.split(':')[0] : key;
    const anchor = Array.from(viewport.querySelectorAll('[data-location]')).find((node) => node.dataset.location === location);
    if (anchor) element('span', String(mark.number), anchor, 'pin').title = mark.comment;
  }
}

function styleRun(node, run) {
  node.style.fontWeight = run.bold ? '700' : '';
  node.style.fontStyle = run.italic ? 'italic' : '';
  node.style.color = run.color || '';
}

function renderWord() {
  const page = element('article', undefined, viewport, 'word');
  function blocks(list, parent) {
    for (const block of list) {
      if (block.rows) {
        const table = element('table', undefined, parent);
        for (const row of block.rows) {
          const tr = element('tr', undefined, table);
          for (const cell of row) blocks(cell, element('td', undefined, tr));
        }
      } else {
        const p = element(block.level ? 'h' + block.level : 'p', undefined, parent);
        p.dataset.location = '¶ ' + block.paragraph;
        for (const run of block.runs) {
          const span = element('span', undefined, p);
          styleRun(span, run);
          if (run.size) span.style.fontSize = run.size + 'pt';
          for (const fragment of run.fragments) {
            if (fragment.image) element('img', undefined, span).src = fragment.image;
            else span.append(document.createTextNode(fragment.text ?? ''));
          }
        }
      }
    }
  }
  blocks(data, page);
}

document.addEventListener('selectionchange', () => {
  clearTimeout(selectionTimer);
  if (format !== 'docx' || !form.hidden) return;
  selectionTimer = setTimeout(() => {
    const selection = window.getSelection();
    const text = selection?.toString().trim();
    if (!text || !selection.rangeCount || !viewport.contains(selection.anchorNode) || !viewport.contains(selection.focusNode)) {
      selectionAction.hidden = true;
      return;
    }
    const range = selection.getRangeAt(0);
    const paragraph = (node) => (node.nodeType === Node.TEXT_NODE ? node.parentElement : node).closest('[data-location]');
    const from = paragraph(range.startContainer);
    const to = paragraph(range.endContainer);
    if (!from || !to) return;
    const preceding = document.createRange();
    preceding.selectNodeContents(from);
    preceding.setEnd(range.startContainer, range.startOffset);
    const offset = preceding.toString().length;
    const location = from.dataset.location + ' · ' + (from === to ? 'UTF-16 offset ' + offset :
      'through ' + to.dataset.location + ', start offset ' + offset);
    const bounds = range.getBoundingClientRect();
    selectionAction.hidden = false;
    position(selectionAction, bounds.left, bounds.bottom + 4);
    selectionAction.onclick = () => openComment({ kind: 'text', location, excerpt: text.slice(0, 1000) }, bounds.left, bounds.bottom + 4);
  }, 160);
});
selectionAction.onpointerdown = (event) => event.preventDefault();

function renderSlides() {
  const deck = element('div', undefined, viewport, 'deck');
  const rail = element('nav', undefined, deck, 'slides');
  const stage = element('section', undefined, deck, 'stage');
  const slide = data.slides[active];
  if (!slide) throw new Error('Presentation has no slides.');
  for (let index = 0; index < data.slides.length; index++) {
    const item = button(String(index + 1), rail, () => choose(index));
    item.setAttribute('aria-current', index === active ? 'true' : 'false');
    const miniature = element('span', undefined, item, 'thumbnail slide');
    drawSlide(miniature, data.slides[index], index + 1, false);
  }
  rail.querySelector('[aria-current=true]').scrollIntoView({ block: 'nearest', inline: 'nearest' });
  const canvas = element('div', undefined, stage, 'slide');
  drawSlide(canvas, slide, active + 1, true);
  let drag;
  canvas.onpointerdown = (event) => {
    if (!mode || submitting || event.button !== 0) return;
    const bounds = canvas.getBoundingClientRect();
    drag = { x: event.clientX, y: event.clientY, bounds, anchor: event.target.closest('[data-location]'),
      outline: element('div', undefined, canvas, 'slide-selection') };
    canvas.setPointerCapture(event.pointerId);
  };
  canvas.onpointermove = (event) => {
    if (!drag) return;
    const x = Math.min(drag.x, event.clientX) - drag.bounds.left;
    const y = Math.min(drag.y, event.clientY) - drag.bounds.top;
    Object.assign(drag.outline.style, { left: x + 'px', top: y + 'px', width: Math.abs(drag.x - event.clientX) + 'px',
      height: Math.abs(drag.y - event.clientY) + 'px' });
  };
  canvas.onpointercancel = () => { drag?.outline.remove(); drag = undefined; };
  canvas.onpointerup = (event) => {
    if (!drag) return;
    const { x, y, bounds, anchor, outline } = drag;
    drag = undefined;
    outline.remove();
    const normalize = (value, length) => Math.max(0, Math.min(1, value / length)).toFixed(3);
    const region = Math.hypot(event.clientX - x, event.clientY - y) > 8;
    const left = normalize(Math.min(x, event.clientX) - bounds.left, bounds.width);
    const top = normalize(Math.min(y, event.clientY) - bounds.top, bounds.height);
    const right = normalize(Math.max(x, event.clientX) - bounds.left, bounds.width);
    const bottom = normalize(Math.max(y, event.clientY) - bounds.top, bounds.height);
    const location = (region ? canvas : anchor).dataset.location + ' · x=' + left + ', y=' + top +
      (region ? ' to x=' + right + ', y=' + bottom : '');
    const excerpt = region ? [...canvas.querySelectorAll('.shape')].filter((node) => {
      const box = node.getBoundingClientRect();
      return box.right >= bounds.left + Number(left) * bounds.width && box.left <= bounds.left + Number(right) * bounds.width &&
        box.bottom >= bounds.top + Number(top) * bounds.height && box.top <= bounds.top + Number(bottom) * bounds.height;
    }).map((node) => node.textContent).join('\n') : anchor === canvas ? '' : anchor.textContent;
    openComment({ kind: 'slide', location, excerpt: excerpt.slice(0, 1000) }, event.clientX + 8, event.clientY + 8);
  };
}

function drawSlide(canvas, slide, number, annotate) {
  canvas.style.aspectRatio = data.width + ' / ' + data.height;
  canvas.style.backgroundColor = slide.background || '#fff';
  if (annotate) canvas.dataset.location = 'Slide ' + number;
  for (const shape of slide.shapes) {
    const box = element('div', undefined, canvas, 'shape');
    if (annotate) box.dataset.location = canvas.dataset.location + ' / ' + (shape.label || 'Shape') + ' #' + shape.id;
    box.style.left = shape.x * 100 + '%';
    box.style.top = shape.y * 100 + '%';
    box.style.width = shape.w * 100 + '%';
    box.style.height = shape.h * 100 + '%';
    box.style.backgroundColor = shape.background || '';
    if (shape.image) element('img', undefined, box).src = shape.image;
    for (const paragraph of shape.paragraphs) {
      const p = element('p', paragraph.bullet ? '• ' : '', box);
      p.style.textAlign = { ctr: 'center', r: 'right', just: 'justify' }[paragraph.align] || 'left';
      for (const run of paragraph.runs) {
        const span = element('span', run.text, p);
        span.style.fontSize = (run.size * 12700 / data.width * 100) + 'cqw';
        styleRun(span, run);
      }
    }
  }
}

function columnName(number) {
  let name = '';
  while (number > 0) {
    number--;
    name = String.fromCharCode(65 + number % 26) + name;
    number = Math.floor(number / 26);
  }
  return name;
}

function renderSheet() {
  const sheet = data[active];
  if (!sheet) throw new Error('Workbook has no worksheets.');
  for (const [index, entry] of data.entries()) {
    const tab = button(entry.name, toolbar, () => choose(index));
    tab.setAttribute('aria-current', index === active ? 'true' : 'false');
  }
  const grid = element('div', undefined, viewport, 'grid');
  const controls = element('div', undefined, grid, 'grid-controls');
  const maxRow = Math.max(20, sheet.rows);
  const maxCol = Math.max(8, sheet.columns);
  const rowEnd = Math.min(rowStart + 99, maxRow);
  const colEnd = Math.min(colStart + 23, maxCol);
  const scroll = element('div', undefined, grid, 'grid-scroll');
  const table = element('table', undefined, scroll);
  const header = element('tr', undefined, element('thead', undefined, table));
  element('th', '', header);
  for (let col = colStart; col <= colEnd; col++) element('th', columnName(col), header);
  const body = element('tbody', undefined, table);
  for (let row = rowStart; row <= rowEnd; row++) {
    const tr = element('tr', undefined, body);
    element('th', String(row), tr);
    for (let col = colStart; col <= colEnd; col++) {
      const address = columnName(col) + row;
      const cell = sheet.cells.get(address);
      const td = element('td', cell?.text || '', tr);
      td.dataset.location = sheet.name + '!' + address;
      td.dataset.row = row;
      td.dataset.col = col;
      td.title = cell?.formula ? '=' + cell.formula : td.textContent;
      if (cell?.style) {
        td.style.backgroundColor = cell.style.background || '';
        styleRun(td, cell.style);
      }
    }
  }
  const cellAt = (event) => document.elementFromPoint(event.clientX, event.clientY)?.closest('td');
  function select(first, last) {
    const left = Math.min(+first.dataset.col, +last.dataset.col);
    const right = Math.max(+first.dataset.col, +last.dataset.col);
    const top = Math.min(+first.dataset.row, +last.dataset.row);
    const bottom = Math.max(+first.dataset.row, +last.dataset.row);
    const start = columnName(left) + top;
    const end = columnName(right) + bottom;
    for (const td of table.querySelectorAll('td')) {
      td.classList.toggle('selected', td.dataset.col >= left && td.dataset.col <= right && td.dataset.row >= top && td.dataset.row <= bottom);
    }
    return { kind: 'cells', location: sheet.name + '!' + start + (start === end ? '' : ':' + end),
      excerpt: sheet.cells.get(start)?.text?.slice(0, 1000) || '' };
  }
  table.onpointerdown = (event) => {
    if (!mode || submitting || event.button !== 0) return;
    const cell = cellAt(event);
    if (!cell) return;
    if (!event.shiftKey || !cellStart) cellStart = cell;
    cell.setPointerCapture(event.pointerId);
    select(cellStart, cell);
  };
  table.onpointermove = (event) => {
    const cell = event.buttons && cellStart && cellAt(event);
    if (cell) select(cellStart, cell);
  };
  table.onpointerup = (event) => {
    const cell = cellStart && cellAt(event);
    if (cell) openComment(select(cellStart, cell), event.clientX + 8, event.clientY + 8);
  };
  table.onpointercancel = () => { cellStart = undefined; };
  button('↑', controls, () => { rowStart -= 100; render(); }).disabled = rowStart === 1;
  button('↓', controls, () => { rowStart += 100; render(); }).disabled = rowEnd >= maxRow;
  button('←', controls, () => { colStart -= 24; render(); }).disabled = colStart === 1;
  button('→', controls, () => { colStart += 24; render(); }).disabled = colEnd >= maxCol;
  element('span', columnName(colStart) + rowStart + ' – ' + columnName(colEnd) + rowEnd, controls);
}

function choose(index) {
  active = index;
  rowStart = colStart = 1;
  render();
}

function render() {
  clearTarget();
  toolbar.replaceChildren(modeButton);
  viewport.replaceChildren();
  if (format === 'docx') renderWord();
  if (format === 'pptx') renderSlides();
  if (format === 'xlsx') renderSheet();
  markers();
}

window.updateOfficeAnnotations = (annotations) => { marks = annotations; markers(); };
window.appendOfficeBytes = (chunk) => { loaded.push(chunk); };
window.renderOffice = (type, strings) => {
  try {
    format = type;
    labels = strings;
    const raw = atob(loaded.join(''));
    loaded = [];
    data = readOfficePreview(Uint8Array.from(raw, (char) => char.charCodeAt(0)), format);
    note.placeholder = labels.placeholder;
    note.setAttribute('aria-label', labels.placeholder);
    selectionAction.textContent = modeButton.textContent = labels.annotate;
    form.querySelector('button[type=submit]').textContent = labels.add;
    form.querySelector('button[type=button]').textContent = labels.cancel;
    modeButton.hidden = format === 'docx';
    render();
    report('ready', {});
  } catch (error) {
    report('error', { message: String(error.message || error).slice(0, 300) });
  }
};
