import { CONTENT_TYPES, OFFICE_REL, PACKAGE_REL, children, elements, openPackage,
  part, related, relPath, root, saveXml, xml, xmlText, zip } from './package.mjs';
import { replaceUnique } from './replace-text.mjs';

const NS = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const DRAWING = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const SLIDE_MIME = 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml';
const EXTENDED = 'http://schemas.openxmlformats.org/officeDocument/2006/extended-properties';

function slideText(value, maximum) {
  if (!xmlText(value).trim() || value.length > maximum || /[\r\n\t]/.test(value)) {
    throw new Error('Expected a single slide line of 1–' + maximum + ' characters.');
  }
  return value;
}

export function pptx(slides) {
  if (!Array.isArray(slides) || !slides.length || slides.length > 100) throw new Error('Expected 1–100 slides.');
  const { entries, main } = openPackage(Uint8Array.fromBase64(__SLIDE_TEMPLATE__), 'pptx');
  const presentation = xml(entries, main);
  const ids = children(root(presentation, NS, 'presentation'), NS, 'sldIdLst')[0];
  ids.removeChild(children(ids, NS, 'sldId')[0]);
  const relsPath = relPath(main);
  const links = xml(entries, relsPath);
  const relationships = root(links, PACKAGE_REL, 'Relationships');
  const templateLink = elements(links, PACKAGE_REL, 'Relationship').find((node) => node.getAttribute('Type') === OFFICE_REL + '/slide');
  relationships.removeChild(templateLink);
  const types = xml(entries, '[Content_Types].xml');
  const overrides = root(types, CONTENT_TYPES, 'Types');
  for (const item of children(overrides, CONTENT_TYPES, 'Override')) {
    const path = item.getAttribute('PartName');
    if (path === '/ppt/slides/slide1.xml' || path.startsWith('/ppt/notesSlides/')) overrides.removeChild(item);
  }
  for (const path of Object.keys(entries)) {
    if (path.startsWith('ppt/notesSlides/')) delete entries[path];
  }
  const slideTemplate = { 'slide.xml': entries['ppt/slides/slide1.xml'] };
  const slideRels = xml(entries, 'ppt/slides/_rels/slide1.xml.rels');
  const notes = elements(slideRels, PACKAGE_REL, 'Relationship').find((node) => node.getAttribute('Type') === OFFICE_REL + '/notesSlide');
  notes.parentNode.removeChild(notes);

  for (let index = 0; index < slides.length; index++) {
    const { title, body = [] } = slides[index];
    const heading = slideText(title, 96);
    if (!Array.isArray(body) || body.length > 8) throw new Error('Each slide supports up to eight bullet points.');
    const slide = xml(slideTemplate, 'slide.xml');
    const [titleBox, bodyBox] = elements(slide, NS, 'txBody');
    elements(titleBox, DRAWING, 't')[0].textContent = heading;
    const paragraph = children(bodyBox, DRAWING, 'p')[0];
    for (const bullet of body) {
      const line = paragraph.cloneNode(true);
      elements(line, DRAWING, 't')[0].textContent = slideText(bullet, 180);
      bodyBox.appendChild(line);
    }
    bodyBox.removeChild(paragraph);
    if (!body.length) bodyBox.parentNode.parentNode.removeChild(bodyBox.parentNode);
    const number = index + 1;
    elements(slide, NS, 'cSld')[0].setAttribute('name', 'Slide ' + number);
    const name = 'slides/slide' + number + '.xml';
    saveXml(entries, 'ppt/' + name, slide);
    saveXml(entries, relPath('ppt/' + name), slideRels);

    const id = 'rIdSlide' + number;
    const node = presentation.createElementNS(NS, 'p:sldId');
    node.setAttribute('id', String(256 + index));
    node.setAttributeNS(OFFICE_REL, 'r:id', id);
    ids.appendChild(node);
    const link = links.createElementNS(PACKAGE_REL, 'Relationship');
    link.setAttribute('Id', id);
    link.setAttribute('Type', OFFICE_REL + '/slide');
    link.setAttribute('Target', name);
    relationships.appendChild(link);
    const override = types.createElementNS(CONTENT_TYPES, 'Override');
    override.setAttribute('PartName', '/ppt/' + name);
    override.setAttribute('ContentType', SLIDE_MIME);
    overrides.appendChild(override);
  }
  saveXml(entries, main, presentation);
  saveXml(entries, relsPath, links);
  saveXml(entries, '[Content_Types].xml', types);
  entries['docProps/app.xml'] = part(`<Properties xmlns="${EXTENDED}"><Application>TinyBot</Application>` +
    '<PresentationFormat>On-screen Show (16:9)</PresentationFormat><Slides>' + slides.length + '</Slides><Notes>0</Notes></Properties>');
  return zip(entries);
}

export function editPptx(bytes, edits) {
  if (!Array.isArray(edits) || !edits.length) throw new Error('Expected at least one PowerPoint text edit.');
  const { entries, main } = openPackage(bytes, 'pptx');
  const presentation = root(xml(entries, main), NS, 'presentation');
  const ids = elements(presentation, NS, 'sldId');
  const slides = new Map();
  for (const { slide, find, replace } of edits) {
    if (!Number.isInteger(slide) || slide < 1 || slide > ids.length) throw new Error('Invalid PowerPoint slide number: ' + slide);
    const path = related(entries, main, 'slide', ids[slide - 1].getAttributeNS(OFFICE_REL, 'id'));
    if (!slides.has(path)) slides.set(path, xml(entries, path));
    const paragraphs = elements(root(slides.get(path), NS, 'sld'), DRAWING, 'p');
    replaceUnique(paragraphs, DRAWING, ['p', 'br', 'fld'], find, replace);
  }
  for (const [path, slide] of slides) saveXml(entries, path, slide);
  return zip(entries);
}
