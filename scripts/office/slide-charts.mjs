import { children, elements, escapeXml, OFFICE_REL, PACKAGE_REL, part, related, relationships, relPath, saveXml, xml } from './package.mjs';
import { xlsx } from './spreadsheet.mjs';

export const CHART = 'http://schemas.openxmlformats.org/drawingml/2006/chart';
const DRAW = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const KINDS = ['bar', 'line', 'doughnut'];
const PALETTE = ['accent', 'accent2', 'muted', '4472C4', '896BB3', '2C998F', 'E6AB4B', 'C76286'];
const SCHEME = { accent: 'accent1', accent2: 'accent2', muted: 'dk2', text: 'dk1', background: 'lt1' };

function first(node, ns, name) {
  return node && children(node, ns, name)[0];
}

function labels(text, maximum, label) {
  if (typeof text !== 'string' || !text.trim() || text.length > maximum) throw new Error('Invalid chart ' + label + '.');
  return escapeXml(text);
}

function colorXml(color) {
  if (typeof color !== 'string' || (!Object.hasOwn(SCHEME, color) && !/^#?[\da-f]{6}$/i.test(color))) {
    throw new Error('Expected a chart theme color or six-digit hex.');
  }
  return Object.hasOwn(SCHEME, color) ? '<a:schemeClr val="' + SCHEME[color] + '"/>' :
    '<a:srgbClr val="' + color.replace(/^#/, '').toUpperCase() + '"/>';
}

function validate(chart) {
  if (!KINDS.includes(chart.chart)) throw new Error('Expected bar, line or doughnut chart.');
  if (!Array.isArray(chart.categories) || !chart.categories.length || chart.categories.length > 30 ||
    !Array.isArray(chart.series) || !chart.series.length || chart.series.length > 6) {
    throw new Error('Expected 1–30 categories and 1–6 chart series.');
  }
  for (const category of chart.categories) labels(category, 120, 'category');
  for (const series of chart.series) {
    if (!series || !Array.isArray(series.values) || series.values.length !== chart.categories.length ||
      series.values.some((number) => !Number.isFinite(number))) throw new Error('Each series needs one finite number per category.');
    labels(series.name, 120, 'series name');
  }
  if (chart.chart === 'doughnut' && (chart.series.length !== 1 || chart.series[0].values.some((value) => value < 0) ||
    !chart.series[0].values.some((value) => value > 0))) throw new Error('A doughnut chart needs one nonnegative series with a positive value.');
  if (chart.title !== undefined) labels(chart.title, 160, 'title');
  if (chart.legend !== undefined && typeof chart.legend !== 'boolean') throw new Error('Chart legend must be a boolean.');
  if (chart.colors !== undefined) {
    if (!Array.isArray(chart.colors) || !chart.colors.length || chart.colors.length > 30) throw new Error('Expected 1–30 chart colors.');
    for (const color of chart.colors) colorXml(color);
  }
}

function xmlNode(document, markup) {
  const node = xml({ 'chart-node.xml': part('<root xmlns:c="' + CHART + '" xmlns:a="' + DRAW + '">' + markup + '</root>') }, 'chart-node.xml');
  return document.importNode(node.documentElement.firstChild, true);
}

function reference(column, values, numeric, header = false) {
  const tag = numeric ? 'num' : 'str';
  const start = header ? 1 : 2;
  const points = values.map((value, index) => '<c:pt idx="' + index + '"><c:v>' +
    escapeXml(String(value)) + '</c:v></c:pt>').join('');
  const cell = 'Sheet1!$' + column + '$' + start + (header ? '' : ':$' + column + '$' + (values.length + 1));
  return '<c:' + tag + 'Ref><c:f>' + cell + '</c:f><c:' + tag + 'Cache>' +
    (numeric ? '<c:formatCode>General</c:formatCode>' : '') + '<c:ptCount val="' + values.length + '"/>' +
    points + '</c:' + tag + 'Cache></c:' + tag + 'Ref>';
}

function seriesXml(chart, series, index, colors) {
  const column = String.fromCharCode(66 + index);
  const color = colorXml(colors[index % colors.length]);
  const fill = '<a:solidFill>' + color + '</a:solidFill>';
  const line = '<a:ln w="28575">' + fill + '</a:ln>';
  const marker = '<c:marker><c:symbol val="circle"/><c:size val="5"/><c:spPr>' + fill + '</c:spPr></c:marker>';
  const points = chart.chart === 'doughnut' ? chart.categories.map((_category, position) =>
    '<c:dPt><c:idx val="' + position + '"/><c:spPr><a:solidFill>' + colorXml(colors[position % colors.length]) +
    '</a:solidFill></c:spPr></c:dPt>').join('') : '';
  return '<c:ser><c:idx val="' + index + '"/><c:order val="' + index + '"/><c:tx>' +
    reference(column, [series.name], false, true) + '</c:tx><c:spPr>' + fill +
    (chart.chart === 'line' ? line + '</c:spPr>' + marker : '</c:spPr>') + points +
    '<c:cat>' + reference('A', chart.categories, false) + '</c:cat><c:val>' +
    reference(column, series.values, true) + '</c:val></c:ser>';
}

function replaceColor(node, document, scheme) {
  const solid = first(node, DRAW, 'solidFill');
  const existing = solid && children(solid, DRAW)[0];
  if (existing) solid.replaceChild(xmlNode(document, '<a:schemeClr val="' + scheme + '"/>'), existing);
}

function chartPackage(entries, chartPath, workbookPath, chart) {
  validate(chart);
  const document = xml({ 'chart.xml': part(__CHART_TEMPLATES__[chart.chart].replace(/^<\?xml[^?]*\?>\s*/, '')) }, 'chart.xml');
  const container = elements(document, CHART, chart.chart + 'Chart')[0];
  const sample = first(container, CHART, 'ser');
  const colors = chart.colors ?? PALETTE;
  chart.series.forEach((series, index) => container.insertBefore(xmlNode(document, seriesXml(chart, series, index, colors)), sample));
  container.removeChild(sample);
  const plot = elements(document, CHART, 'chart')[0];
  const title = first(plot, CHART, 'title');
  if (chart.title === undefined) {
    if (title) plot.removeChild(title);
    first(plot, CHART, 'autoTitleDeleted')?.setAttribute('val', '1');
  } else {
    const text = elements(title, DRAW, 't')[0];
    text.textContent = chart.title;
  }
  if (!(chart.legend ?? (chart.series.length > 1 || chart.chart === 'doughnut'))) {
    const legend = first(plot, CHART, 'legend');
    if (legend) plot.removeChild(legend);
  }
  for (const name of ['rPr', 'defRPr']) {
    for (const style of elements(document, DRAW, name)) {
      replaceColor(style, document, 'dk1');
      first(style, DRAW, 'latin')?.setAttribute('typeface', '+mn-lt');
    }
  }
  const background = first(document.documentElement, CHART, 'spPr');
  const fill = first(background, DRAW, 'solidFill');
  if (fill) background.replaceChild(xmlNode(document, '<a:noFill/>'), fill);
  elements(document, CHART, 'externalData')[0].setAttributeNS(OFFICE_REL, 'r:id', 'rId1');
  saveXml(entries, chartPath, document);
  const workbook = workbookPath.slice(workbookPath.lastIndexOf('/') + 1);
  entries[relPath(chartPath)] = relationships([['rId1', 'package', '../embeddings/' + workbook]]);
  entries[workbookPath] = xlsx([{ name: 'Sheet1', rows: [
    ['Category', ...chart.series.map((series) => series.name)],
    ...chart.categories.map((name, index) => [name, ...chart.series.map((series) => series.values[index])])
  ] }]);
}

export function addSlideChart(entries, slidePath, links, elementId, chart) {
  const root = links.documentElement;
  const used = new Set(children(root, PACKAGE_REL, 'Relationship').map((link) => link.getAttribute('Id')));
  const stem = slidePath.slice(slidePath.lastIndexOf('/') + 1, -4) + '-' + elementId;
  const chartPath = 'ppt/charts/tinybot-' + stem + '.xml';
  const workbookPath = 'ppt/embeddings/tinybot-' + stem + '.xlsx';
  if (Object.hasOwn(entries, chartPath) || Object.hasOwn(entries, workbookPath)) throw new Error('Duplicate chart part.');
  let suffix = 1;
  while (used.has('rIdTinybotChart' + suffix)) suffix++;
  const id = 'rIdTinybotChart' + suffix;
  chartPackage(entries, chartPath, workbookPath, chart);
  const link = links.createElementNS(PACKAGE_REL, 'Relationship');
  link.setAttribute('Id', id);
  link.setAttribute('Type', OFFICE_REL + '/chart');
  link.setAttribute('Target', '../charts/tinybot-' + stem + '.xml');
  root.appendChild(link);
  return id;
}

function cache(node, kind) {
  if (!node) return [];
  const pointCache = [kind + 'Cache', 'multiLvlStrCache', kind + 'Lit'].map((tag) => elements(node, CHART, tag)[0]).find(Boolean);
  return pointCache ? elements(pointCache, CHART, 'v').map((point) => point.textContent) : [];
}

function readColor(node) {
  const fill = first(first(node, CHART, 'spPr'), DRAW, 'solidFill');
  const slot = first(fill, DRAW, 'schemeClr')?.getAttribute('val');
  return first(fill, DRAW, 'srgbClr')?.getAttribute('val') || Object.keys(SCHEME).find((name) => SCHEME[name] === slot);
}

export function slideChart(entries, slidePath, element) {
  const id = elements(element, CHART, 'chart')[0]?.getAttributeNS(OFFICE_REL, 'id');
  if (!id) return undefined;
  const chartPath = related(entries, slidePath, 'chart', id);
  const document = xml(entries, chartPath);
  const chart = KINDS.find((kind) => elements(document, CHART, kind + 'Chart').length);
  if (!chart) return undefined;
  const container = elements(document, CHART, chart + 'Chart')[0];
  const entriesInChart = children(container, CHART, 'ser');
  if (!entriesInChart.length) return undefined;
  const categories = cache(first(entriesInChart[0], CHART, 'cat'), 'str');
  const series = entriesInChart.map((item) => ({ name: cache(first(item, CHART, 'tx'), 'str')[0] || '',
    values: cache(first(item, CHART, 'val'), 'num').map(Number) }));
  if (!categories.length || series.some((item) => item.values.length !== categories.length)) return undefined;
  const colors = (chart === 'doughnut' ? children(entriesInChart[0], CHART, 'dPt') : entriesInChart)
    .map((item, index) => readColor(item) || PALETTE[index % PALETTE.length]);
  const title = elements(document, CHART, 'title')[0];
  return { chart, chartPath, categories, series, colors: colors.length ? colors : PALETTE,
    title: title ? elements(title, DRAW, 't').map((node) => node.textContent).join('') || undefined : undefined,
    legend: !!elements(document, CHART, 'legend').length };
}

export function updateSlideChart(entries, slidePath, element, changes) {
  const previous = slideChart(entries, slidePath, element);
  if (!previous || !previous.chartPath.startsWith('ppt/charts/tinybot-')) throw new Error('Expected a chart created by Tinybot.');
  const workbook = related(entries, previous.chartPath, 'package');
  chartPackage(entries, previous.chartPath, workbook, { ...previous, ...changes });
}
