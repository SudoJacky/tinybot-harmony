import { OFFICE_REL, elements, escapeXml, newPackage, openPackage, part, relationships, root, saveXml, xml, xmlText, zip } from './package.mjs';
import { replaceUnique } from './replace-text.mjs';

const NS = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const STYLES = 'application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml';

function paragraph(text, style) {
  const pieces = xmlText(text).split(/(\r\n|\r|\n|\t)/).map((piece) => {
    if (piece === '\t') return '<w:tab/>';
    if (/^[\r\n]/.test(piece)) return '<w:br/>';
    return '<w:t xml:space="preserve">' + escapeXml(piece) + '</w:t>';
  });
  return '<w:p>' + (style ? '<w:pPr><w:pStyle w:val="' + style + '"/></w:pPr>' : '') +
    '<w:r>' + pieces.join('') + '</w:r></w:p>';
}

function table(rows) {
  if (!Array.isArray(rows) || !rows.length || !Array.isArray(rows[0]) || !rows[0].length || rows[0].length > 63) {
    throw new Error('Expected a non-empty Word table with up to 63 columns.');
  }
  const width = rows[0].length;
  const gridColumn = '<w:gridCol w:w="' + Math.floor(9360 / width) + '"/>';
  const borders = ['top', 'left', 'bottom', 'right', 'insideH', 'insideV'].map((edge) =>
    '<w:' + edge + ' w:val="single" w:sz="4" w:color="C8D2DE"/>').join('');
  const content = rows.map((row, index) => {
    if (!Array.isArray(row) || row.length !== width) throw new Error('Word table rows must all have the same number of columns.');
    return '<w:tr>' + (index === 0 ? '<w:trPr><w:tblHeader/></w:trPr>' : '') +
      row.map((value) => '<w:tc>' + paragraph(value) + '</w:tc>').join('') + '</w:tr>';
  }).join('');
  return '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>' + borders + '</w:tblBorders></w:tblPr>' +
    '<w:tblGrid>' + gridColumn.repeat(width) + '</w:tblGrid>' + content + '</w:tbl>';
}

export function docx(blocks) {
  if (!Array.isArray(blocks) || !blocks.length) throw new Error('Expected Word blocks with heading, text, or table.');
  const body = blocks.map((block) => {
    if (!block || typeof block !== 'object' || ['heading', 'text', 'table'].filter((key) => Object.hasOwn(block, key)).length !== 1) {
      throw new Error('Expected one Word heading, text, or table per block.');
    }
    if (Object.hasOwn(block, 'heading')) {
      const level = block.level ?? 1;
      if (!Number.isInteger(level) || level < 1 || level > 3) throw new Error('Word heading level must be 1–3.');
      return paragraph(block.heading, 'Heading' + level);
    }
    if (Object.hasOwn(block, 'text')) return paragraph(block.text);
    return table(block.table);
  }).join('');
  const headings = [1, 2, 3].map((level) => `<w:style w:type="paragraph" w:styleId="Heading${level}">` +
    `<w:name w:val="heading ${level}"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>` +
    `<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="100"/><w:outlineLvl w:val="${level - 1}"/></w:pPr>` +
    `<w:rPr><w:b/><w:color w:val="24374A"/><w:sz w:val="${38 - level * 4}"/></w:rPr></w:style>`).join('');
  return newPackage('docx', 'word/document.xml', {
    'word/document.xml': part(`<w:document xmlns:w="${NS}" xmlns:r="${OFFICE_REL}"><w:body>${body}` +
      '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" ' +
      'w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>'),
    'word/styles.xml': part(`<w:styles xmlns:w="${NS}"><w:style w:type="paragraph" w:default="1" w:styleId="Normal">` +
      '<w:name w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="120"/></w:pPr><w:rPr><w:sz w:val="22"/></w:rPr>' +
      '</w:style>' + headings + '</w:styles>'),
    'word/_rels/document.xml.rels': relationships([['rId1', 'styles', 'styles.xml']]),
  }, [['word/styles.xml', STYLES]]);
}

export function editDocx(bytes, edits) {
  if (!Array.isArray(edits) || !edits.length) throw new Error('Expected at least one Word text edit.');
  const { entries, main } = openPackage(bytes, 'docx');
  const document = xml(entries, main);
  const body = elements(root(document, NS, 'document'), NS, 'body')[0];
  if (!body) throw new Error('Word document has no body.');
  const paragraphs = elements(body, NS, 'p').filter((p) =>
    !['fldChar', 'fldSimple', 'instrText'].some((tag) => elements(p, NS, tag).length));
  for (const { find, replace } of edits) {
    replaceUnique(paragraphs, NS, ['p', 'tab', 'br', 'cr', 'del', 'moveFrom', 'drawing', 'pict', 'sym'], find, replace, true);
  }
  saveXml(entries, main, document);
  return zip(entries);
}
