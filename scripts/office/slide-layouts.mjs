const WIDTH = 13 + 1 / 3;
const MARGIN = 0.75;
const CONTENT = WIDTH - 2 * MARGIN;

// These layouts leave room for two-line CJK titles and size reading text independently of footnotes.
export function layoutSlide(slide) {
  if (!slide?.layout) return slide;
  const { layout, title, subtitle, source, points = [], metrics = [], charts = [] } = slide;
  if (!title || !Array.isArray(points) || !Array.isArray(metrics) || !Array.isArray(charts) || slide.elements !== undefined) {
    throw new Error('A slide layout needs a title and cannot be combined with elements.');
  }
  const elements = [];
  const text = (id, value, x, y, w, h, fontSize, color = 'text', bold = false) => {
    if (value !== undefined && value !== '') elements.push({ id, type: 'text', text: value, x, y, w, h, fontSize, color, bold });
  };
  const metricRow = (y) => {
    if (metrics.length > 4) throw new Error('Use up to four metrics per slide.');
    const step = CONTENT / metrics.length;
    metrics.forEach(({ label, value }, index) => {
      const x = MARGIN + index * step;
      text('metric-' + (index + 1), value, x, y, step - 0.24, 0.64, 36, 'accent', true);
      text('metric-label-' + (index + 1), label, x, y + 0.7, step - 0.24, 0.7, 17, 'muted');
    });
  };
  const pointList = (x, y, width, step) => {
    for (let index = 0; index < points.length; index++) {
      text('point-' + (index + 1), '•  ' + points[index], x, y + index * step, width, step - 0.08, 19);
    }
  };
  if (layout === 'cover') {
    if (charts.length || points.length) throw new Error('Cover supports a subtitle and up to four metrics.');
    text('title', title, MARGIN, 1.64, CONTENT, 1.55, 46, 'text', true);
    text('subtitle', subtitle, MARGIN, 3.42, CONTENT, 0.84, 23, 'muted');
    metricRow(5.04);
  } else {
    text('title', title, MARGIN, 0.52, CONTENT, 1.15, 32, 'text', true);
    text('subtitle', subtitle, MARGIN, 1.79, CONTENT, 0.62, 18, 'muted');
    if (layout === 'chart') {
      if (charts.length < 1 || charts.length > 2 || metrics.length || points.length > 3 ||
          (charts.length === 2 && points.length > 1)) {
        throw new Error('Chart layout takes 1 chart and up to 3 points, or 2 charts and up to 1 point.');
      }
      const twoCharts = charts.length === 2;
      const w = twoCharts ? (CONTENT - 0.36) / 2 : points.length ? 7.4 : CONTENT;
      charts.forEach((chart, index) => {
        elements.push({ ...chart, id: 'chart-' + (index + 1), type: 'chart', x: MARGIN + index * (w + 0.36), y: 2.51, w,
          h: twoCharts && points.length ? 3.48 : 4.2 });
      });
      if (twoCharts) pointList(MARGIN, 6.15, CONTENT, 0.66);
      else pointList(MARGIN + w + 0.38, 2.68, CONTENT - w - 0.38, 1.32);
    } else if (layout === 'summary') {
      if (charts.length || points.length > 4) throw new Error('Summary layout takes metrics and up to four brief points.');
      metricRow(2.58);
      pointList(MARGIN, metrics.length ? 4.23 : 2.58, CONTENT, metrics.length ? 0.66 : 1.0);
    } else {
      throw new Error('Expected slide layout cover, chart, or summary.');
    }
  }
  text('source', source, MARGIN, 7.01, CONTENT, 0.32, 11, 'muted');
  return { background: slide.background, elements };
}
