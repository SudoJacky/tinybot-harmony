import { mathjax } from 'mathjax-full/js/mathjax.js';
import { TeX } from 'mathjax-full/js/input/tex.js';
import { SVG } from 'mathjax-full/js/output/svg.js';
import { SVGWrapperFactory } from 'mathjax-full/js/output/svg/WrapperFactory.js';
import { SVGmtable } from 'mathjax-full/js/output/svg/Wrappers/mtable.js';
import { liteAdaptor } from 'mathjax-full/js/adaptors/liteAdaptor.js';
import { RegisterHTMLHandler } from 'mathjax-full/js/handlers/html.js';
import 'mathjax-full/js/input/tex/ams/AmsConfiguration.js';
import 'mathjax-full/js/input/tex/boldsymbol/BoldsymbolConfiguration.js';
import 'mathjax-full/js/input/tex/cancel/CancelConfiguration.js';
import 'mathjax-full/js/input/tex/color/ColorConfiguration.js';
import 'mathjax-full/js/input/tex/mathtools/MathtoolsConfiguration.js';
import 'mathjax-full/js/input/tex/newcommand/NewcommandConfiguration.js';
import 'mathjax-full/js/input/tex/textmacros/TextMacrosConfiguration.js';

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
class StandaloneTable extends SVGmtable {
  getPercentageWidth() {
    super.getPercentageWidth();
    if (this.isTop && this.hasLabels) {
      // Draw equation numbers in the same coordinate space as the equation.
      this.isTop = false;
      this.bbox.pwidth = '';
    }
  }
}
const wrapperFactory = new SVGWrapperFactory();
wrapperFactory.setNodeClass('mtable', StandaloneTable);
// Explicit paths avoid relying on SVG 2 or a shared glyph table in the image decoder.
const output = new SVG({ fontCache: 'none', wrapperFactory });

export function typesetMath(tex, display, color) {
  // Keep macro definitions and equation labels local to this expression.
  const input = new TeX({
    packages: ['base', 'ams', 'boldsymbol', 'cancel', 'color', 'mathtools', 'newcommand', 'textmacros'],
    maxBuffer: 8192,
    maxMacros: 1000,
    formatError: (_jax, error) => { throw error; },
  });
  const document = mathjax.document('', { InputJax: input, OutputJax: output });
  const svg = adaptor.firstChild(document.convert(tex, { display, containerWidth: 0 }));
  const [, y, w, h] = adaptor.getAttribute(svg, 'viewBox').split(' ').map(Number);
  const width = w / 1000;
  const height = h / 1000;
  const descent = (y + h) / 1000;
  if (![width, height, descent].every(Number.isFinite) || width > 256 || height > 48) {
    throw Error('Formula dimensions are out of range');
  }
  const group = adaptor.firstChild(svg);
  adaptor.setAttribute(group, 'fill', color);
  adaptor.setAttribute(group, 'stroke', color);
  for (const node of adaptor.tags(svg, 'line').concat(adaptor.tags(svg, 'rect'))) {
    if (adaptor.hasAttribute(node, 'data-line') || adaptor.hasAttribute(node, 'data-frame')) {
      adaptor.setAttribute(node, 'stroke-width', '70');
      adaptor.setAttribute(node, 'fill', 'none');
    }
  }
  adaptor.removeAttribute(svg, 'style');
  adaptor.setAttribute(svg, 'width', String(Math.max(1, Math.ceil(width * 16))));
  adaptor.setAttribute(svg, 'height', String(Math.max(1, Math.ceil(height * 16))));
  return { svg: adaptor.outerHTML(svg), width, height, descent };
}
