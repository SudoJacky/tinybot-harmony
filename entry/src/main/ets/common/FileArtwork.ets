export function filePreviewIcon(path: string): Resource {
  if (/\.(png|jpe?g|webp|gif|bmp)$/i.test(path)) { return $r('sys.symbol.picture'); }
  if (/\.(xlsx|csv|tsv)$/i.test(path)) { return $r('sys.symbol.grid'); }
  if (/\.pptx$/i.test(path)) { return $r('sys.symbol.display'); }
  if (/\.pdf$/i.test(path)) { return $r('sys.symbol.pdf_doc'); }
  if (/\.(txt|md|markdown|log)$/i.test(path)) { return $r('sys.symbol.doc_plaintext'); }
  return $r('sys.symbol.doc_text');
}
