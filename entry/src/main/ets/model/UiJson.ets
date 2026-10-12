import { UiDiagnosticError } from './UiRepair';
// Keep the location supplied by our protocol even when Ark's JSON parser omits offsets.
export function parseUiJson(source: string, location: string): Object {
  try { return JSON.parse(source) as Object; }
  catch (error) {
    const detail = (error as Error).message;
    const match = detail.match(/position (\d+)/);
    const offset = match ? Number(match[1]) : undefined;
    const excerpt = offset === undefined ? source.slice(-180) : source.slice(Math.max(0, offset - 80), offset + 100);
    throw new UiDiagnosticError('JSON_SYNTAX', 'UI JSON syntax error at ' + location + (offset === undefined ? '' : ', character ' + (offset + 1)) +
      ': ' + detail + '\n' + (offset === undefined ? 'Record tail: ' : 'Nearby text: ') + JSON.stringify(excerpt),
      { field: location, character: offset === undefined ? undefined : offset + 1,
        characterScope: offset === undefined ? undefined : location === 'record' ? 'JSONL record' : 'decoded node.data' }, excerpt);
  }
}
