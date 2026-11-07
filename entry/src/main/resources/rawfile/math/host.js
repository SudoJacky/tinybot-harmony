// The only executable input is this packaged host and KaTeX. Reply content is JSON data.
const root = document.getElementById('content');
let revision = 0;
let previousHeight = '';
function measure() {
  const title = 'math:' + revision + ':' + Math.ceil(root.getBoundingClientRect().height);
  if (title !== previousHeight) { previousHeight = title; document.title = title; }
}
window.renderMath = function (data) {
  revision = data.revision;
  root.style.fontSize = data.size + 'px';
  root.style.color = data.color;
  root.style.fontWeight = data.bold ? 'bold' : 'normal';
  root.style.userSelect = data.selectable ? 'text' : 'none';
  root.replaceChildren();
  for (const span of data.spans) {
    const element = document.createElement(span.kind === 'link' ? 'a' : 'span');
    if (span.kind === 'math') {
      katex.render(span.text, element, { displayMode: data.display, throwOnError: false,
        trust: false, strict: 'warn', maxExpand: 1000, maxSize: 20, output: 'htmlAndMathml' });
      element.className = data.display ? 'formula display' : 'formula';
    } else {
      element.textContent = span.text;
      if (span.kind === 'link') { element.href = span.url; element.style.color = data.accent; }
      if (span.kind === 'bold') element.style.fontWeight = 'bold';
      if (span.kind === 'italic') element.style.fontStyle = 'italic';
      if (span.kind === 'strike') element.style.textDecoration = 'line-through';
      if (span.kind === 'code') element.className = 'code';
    }
    root.append(element);
  }
  measure();
  document.fonts.ready.then(measure);
};
new ResizeObserver(measure).observe(root);
