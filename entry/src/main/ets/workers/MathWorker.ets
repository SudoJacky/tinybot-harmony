import { util, worker, MessageEvents } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { MathDrawing, MathRequest, MathResponse } from '../model/MathContent';
import { typesetMath } from './MathEngine';

const port = worker.workerPort;
const encoder = new util.TextEncoder();

port.onmessage = (event: MessageEvents): void => {
  const job = event.data as MathRequest;
  let response: MathResponse = { width: 0, height: 0, descent: 0, bytes: 0 };
  let drawing: MathDrawing;
  try {
    drawing = typesetMath(job.tex, job.display, job.color) as MathDrawing;
  } catch (_) {
    response.error = 'invalid_formula';
    port.postMessage(response);
    return;
  }
  try {
    const data = encoder.encodeInto(drawing.svg);
    if (data.byteLength > 256 * 1024) {
      response.error = 'formula_too_large';
    } else {
      const file = fs.openSync(job.path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        if (fs.writeSync(file.fd, data.buffer as ArrayBuffer) !== data.byteLength) {
          throw new Error('Short formula cache write');
        }
      } finally {
        fs.closeSync(file);
      }
      response = { width: drawing.width, height: drawing.height, descent: drawing.descent, bytes: data.byteLength };
    }
  } catch (_) {
    response.error = 'cache_write_failed';
  }
  port.postMessage(response);
};
