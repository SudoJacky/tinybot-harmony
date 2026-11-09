import { xmlText } from './package.mjs';

function groups(paragraph, namespace, breaks) {
  const result = [];
  let nodes = [];
  function flush() {
    if (nodes.length) result.push(nodes);
    nodes = [];
  }
  function walk(node) {
    if (node.nodeType !== 1) return;
    if (node.namespaceURI === namespace && node.localName === 't' &&
        node.parentNode.namespaceURI === namespace && node.parentNode.localName === 'r') {
      nodes.push(node);
    } else if (node.namespaceURI === namespace && breaks.includes(node.localName)) {
      flush();
    } else {
      for (const child of Array.from(node.childNodes)) walk(child);
    }
  }
  for (const child of Array.from(paragraph.childNodes)) walk(child);
  flush();
  return result;
}

export function replaceUnique(paragraphs, namespace, breaks, find, replace, preserveSpaces = false) {
  if (!xmlText(find).length || /[\r\n\t]/.test(find) || /[\r\n\t]/.test(xmlText(replace))) {
    throw new Error('Text edits require a non-empty match and single-line text.');
  }
  let match;
  for (const paragraph of paragraphs) {
    for (const nodes of groups(paragraph, namespace, breaks)) {
      const text = nodes.map((node) => node.textContent).join('');
      const index = text.indexOf(find);
      if (index < 0) continue;
      if (match || text.indexOf(find, index + 1) >= 0) throw new Error('Text edit is ambiguous. Provide a unique match.');
      match = { nodes, index };
    }
  }
  if (!match) throw new Error('Text edit did not match. Use exact text within one paragraph.');
  let offset = 0;
  let first = true;
  const end = match.index + find.length;
  for (const node of match.nodes) {
    const text = node.textContent;
    const next = offset + text.length;
    if (next > match.index && offset < end && text.length) {
      node.textContent = text.slice(0, Math.max(0, match.index - offset)) + (first ? replace : '') +
        text.slice(Math.min(text.length, end - offset));
      if (preserveSpaces) node.setAttributeNS('http://www.w3.org/XML/1998/namespace', 'xml:space', 'preserve');
      first = false;
    }
    offset = next;
  }
}
