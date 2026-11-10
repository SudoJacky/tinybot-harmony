const SVG = 'http://www.w3.org/2000/svg';

function add(parent, tag, attributes, label) {
  const element = document.createElementNS(SVG, tag);
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
  if (label !== undefined) element.textContent = label;
  parent.append(element);
  return element;
}

function short(label, maximum) {
  const chars = Array.from(label);
  return chars.length > maximum ? chars.slice(0, maximum - 1).join('') + '…' : label;
}

function format(value) {
  return new Intl.NumberFormat(undefined, { maximumSignificantDigits: 4, notation: 'compact' }).format(value);
}

export function drawSlideChart(box, chart, theme) {
  const text = '#' + (theme?.text || '263C51');
  const muted = '#' + (theme?.muted || '63748A');
  const color = (index) => {
    const value = chart.colors[index % chart.colors.length];
    return '#' + (theme?.[value] || (/^[\da-f]{6}$/i.test(value) ? value : '207F78'));
  };
  const svg = add(box, 'svg', { viewBox: '0 0 640 360', 'aria-hidden': 'true',
    'font-family': theme?.fontFace || 'system-ui, sans-serif' });
  if (chart.title) add(svg, 'text', { x: 16, y: 26, fill: text, 'font-size': 22, 'font-weight': 700 }, short(chart.title, 49));
  const top = chart.title ? 48 : 18;
  if (chart.chart === 'doughnut') {
    const values = chart.series[0].values;
    const max = Math.max(...values);
    const total = values.reduce((sum, value) => sum + value / max, 0);
    const radius = (360 - top - 38) / 2;
    const cy = top + radius + 2;
    const cx = chart.legend ? 220 : 320;
    let position = 0;
    values.forEach((value, index) => {
      const fraction = (value / max) / total;
      if (!fraction) return;
      add(svg, 'circle', { cx, cy, r: radius * 0.74, fill: 'none', stroke: color(index), 'stroke-width': radius * 0.46,
        pathLength: 1, 'stroke-dasharray': fraction + ' ' + (1 - fraction), 'stroke-dashoffset': -position,
        transform: 'rotate(-90 ' + cx + ' ' + cy + ')' });
      position += fraction;
    });
    if (chart.legend) {
      const visible = chart.categories.slice(0, 12);
      visible.forEach((label, index) => {
        const y = top + index * 21 + 15;
        add(svg, 'circle', { cx: 395, cy: y - 4, r: 5, fill: color(index) });
        add(svg, 'text', { x: 407, y, fill: text, 'font-size': 14 }, short(label, 21));
      });
    }
    return;
  }
  const left = 60;
  const bottom = chart.legend ? 287 : 314;
  const plotWidth = 558;
  const values = chart.series.flatMap((item) => item.values);
  const low = Math.min(0, ...values), high = Math.max(0, ...values);
  const scale = Math.max(Math.abs(low), Math.abs(high), 1);
  const span = (high / scale - low / scale) || 1;
  const y = (value) => bottom - (value / scale - low / scale) / span * (bottom - top);
  for (let index = 0; index <= 4; index++) {
    const value = (low / scale + span * index / 4) * scale;
    const lineY = bottom - (bottom - top) * index / 4;
    add(svg, 'line', { x1: left, x2: left + plotWidth, y1: lineY, y2: lineY, stroke: muted, 'stroke-opacity': 0.24 });
    add(svg, 'text', { x: left - 8, y: lineY + 4, fill: muted, 'font-size': 12, 'text-anchor': 'end' }, format(value));
  }
  const step = plotWidth / chart.categories.length;
  const labelStep = Math.ceil(chart.categories.length / 8);
  chart.categories.forEach((label, index) => {
    if (index % labelStep === 0) add(svg, 'text', { x: left + step * (index + 0.5), y: bottom + 20,
      fill: text, 'font-size': 12, 'text-anchor': 'middle' }, short(label, 10));
  });
  chart.series.forEach((item, index) => {
    const stroke = color(index);
    if (chart.chart === 'bar') {
      const width = step * 0.8 / chart.series.length;
      item.values.forEach((value, position) => add(svg, 'rect', { x: left + step * (position + 0.1) + width * index,
        y: Math.min(y(value), y(0)), width: Math.max(1, width - 1), height: Math.abs(y(value) - y(0)), fill: stroke }));
    } else {
      const points = item.values.map((value, position) => [left + step * (position + 0.5), y(value)]);
      add(svg, 'polyline', { points: points.map((point) => point.join(',')).join(' '), fill: 'none', stroke, 'stroke-width': 3 });
      for (const [cx, cy] of points) add(svg, 'circle', { cx, cy, r: 4, fill: stroke });
    }
    if (chart.legend) {
      const x = 12 + index * (616 / chart.series.length);
      add(svg, 'circle', { cx: x + 6, cy: 336, r: 5, fill: stroke });
      add(svg, 'text', { x: x + 18, y: 340, fill: text, 'font-size': 13 }, short(item.name, chart.series.length > 4 ? 9 : 13));
    }
  });
}
