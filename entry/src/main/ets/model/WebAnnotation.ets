import { FileAnnotationTarget } from './FileAnnotation';

export interface WebAnnotationTarget extends FileAnnotationTarget {
  x: number;
  y: number;
}

export interface WebAnnotationMark {
  number: number;
  location: string;
}

export function webAnnotationScript(): string {
  return `(() => {
    let enabled = false, marks = [], selected = '', layer, scheduled = false;
    const pathFor = element => {
      const path = [];
      for (let node = element; node && node !== document.body; node = node.parentElement) {
        if (node.id) {
          const selector = '#' + CSS.escape(node.id);
          if (document.querySelectorAll(selector).length === 1) { path.unshift(selector); break; }
        }
        const siblings = [...node.parentElement.children].filter(sibling => sibling.localName === node.localName);
        path.unshift(CSS.escape(node.localName) + ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')');
      }
      return path.length ? path.join(' > ') : 'body';
    };
    const draw = () => {
      scheduled = false;
      if (!document.body) return;
      if (!layer?.isConnected) {
        layer = document.createElement('div');
        layer.setAttribute('aria-hidden', 'true');
        layer.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none;overflow:hidden';
        document.body.append(layer);
      }
      layer.replaceChildren();
      for (const mark of selected ? [...marks, {location:selected,number:0}] : marks) {
        let node;
        try { node = document.querySelector(mark.location); } catch { continue; }
        if (!node) continue;
        const box = node.getBoundingClientRect();
        if (!box.width || !box.height || box.right < 0 || box.bottom < 0 || box.left > innerWidth || box.top > innerHeight) continue;
        const indicator = document.createElement('span');
        indicator.style.cssText = 'position:absolute;box-sizing:border-box;pointer-events:none;';
        if (mark.number) {
          indicator.textContent = String(mark.number);
          indicator.style.cssText += 'background:#2769d9;color:white;border:1px solid white;border-radius:16px;min-width:20px;text-align:center;font:600 12px/19px system-ui';
          indicator.style.left = Math.max(0, Math.min(innerWidth - 22, box.right - 12)) + 'px';
          indicator.style.top = Math.max(0, box.top - 10) + 'px';
        } else {
          indicator.style.cssText += 'border:2px dashed #3770e4;background:#3770e415';
          Object.assign(indicator.style, {left:box.left+'px',top:box.top+'px',width:box.width+'px',height:box.height+'px'});
        }
        layer.append(indicator);
      }
    };
    const redraw = () => { if (!scheduled && (layer || marks.length || selected)) { scheduled = true; requestAnimationFrame(draw); } };
    addEventListener('scroll', redraw, true);
    addEventListener('resize', redraw);
    addEventListener('message', event => {
      if (event.source !== parent || event.data?.channel !== 'tinybot-host' || event.data.type !== 'annotationState') return;
      enabled = event.data.enabled === true;
      marks = event.data.marks;
      if (!enabled || event.data.clear) selected = '';
      redraw();
    });
    addEventListener('click', event => {
      if (!enabled || !event.isTrusted || !(event.target instanceof Element) || !document.body?.contains(event.target)) return;
      event.preventDefault(); event.stopImmediatePropagation();
      const node = event.target.closest('h1,h2,h3,h4,h5,h6,button,a,p,img,canvas,svg,[role=button]') || event.target;
      selected = pathFor(node);
      if (selected.length > 1000) return;
      const label = (node.getAttribute('aria-label') || node.getAttribute('alt') || node.textContent || '').trim().slice(0, 1000);
      parent.postMessage({channel:'tinybot-frame',type:'annotationTarget',target:{
        kind:'element',location:selected,excerpt:label,x:event.clientX / innerWidth,y:event.clientY / innerHeight}}, '*');
      redraw();
    }, true);
  })();`;
}
