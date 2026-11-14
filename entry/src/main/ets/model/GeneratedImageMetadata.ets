import { exportMetadata, insertPngText } from './ExportMetadata';

// TC260-PG-20259A §6 serializes the seven Appendix E fields inside the XMP property.
export function generatedImageXmp(id: string): string {
  const fields = JSON.stringify(exportMetadata(id).AIGC)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' +
    '<rdf:Description rdf:about="" xmlns:TC260="http://www.tc260.org.cn/ns/AIGC/1.0/"><TC260:AIGC>' +
    fields + '</TC260:AIGC></rdf:Description></rdf:RDF></x:xmpmeta>';
}

// The input is a newly packed raster. The packer writes pixel data without copying source metadata.
export function embedGeneratedImageXmp(source: Uint8Array, mime: string, xmp: Uint8Array,
  width: number, height: number): Uint8Array {
  if (mime === 'image/png') { return insertPngText(source, 'XML:com.adobe.xmp', xmp); }
  if (mime === 'image/jpeg') { return jpegXmp(source, xmp); }
  if (mime === 'image/webp') { return webpXmp(source, xmp, width, height); }
  throw new Error('Unsupported generated image format.');
}

function jpegXmp(source: Uint8Array, xmp: Uint8Array): Uint8Array {
  const namespace = 'http://ns.adobe.com/xap/1.0/\0';
  const size = 2 + namespace.length + xmp.length;
  const at = source[2] === 0xff && source[3] === 0xe0 ? 4 + (source[4] << 8) + source[5] : 2;
  if (at >= source.length || size > 0xffff) { throw new Error('Invalid JPEG XMP segment.'); }
  const output = new Uint8Array(source.length + 2 + size);
  output.set(source.subarray(0, at));
  output.set([0xff, 0xe1, size >>> 8, size & 0xff], at);
  for (let i = 0; i < namespace.length; i++) { output[at + 4 + i] = namespace.charCodeAt(i); }
  output.set(xmp, at + 4 + namespace.length);
  output.set(source.subarray(at), at + 2 + size);
  return output;
}

function webpXmp(source: Uint8Array, xmp: Uint8Array, width: number, height: number): Uint8Array {
  const extended = source[12] === 86 && source[13] === 80 && source[14] === 56 && source[15] === 88; // VP8X
  const headerSize = extended ? 0 : 18;
  const at = source.length + headerSize;
  const output = new Uint8Array(at + 8 + xmp.length + (xmp.length % 2));
  const view = new DataView(output.buffer);
  output.set(source.subarray(0, 12));
  view.setUint32(4, output.length - 8, true);
  if (!extended) {
    const alpha = source[15] === 76 && (source[24] & 0x10) !== 0; // VP8L alpha-used bit
    output.set([86, 80, 56, 88, 10, 0, 0, 0, alpha ? 0x10 : 0, 0, 0, 0], 12);
    for (let i = 0; i < 3; i++) {
      output[24 + i] = ((width - 1) >>> (8 * i)) & 0xff;
      output[27 + i] = ((height - 1) >>> (8 * i)) & 0xff;
    }
  }
  output.set(source.subarray(12), 12 + headerSize);
  output[20] |= 0x04; // VP8X XMP present
  output.set([88, 77, 80, 32], at); // XMP followed by a space
  view.setUint32(at + 4, xmp.length, true);
  output.set(xmp, at + 8);
  return output;
}
