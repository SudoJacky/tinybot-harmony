export interface AnswerReferencePart { kind: string; content: string; previewId: string; panelKey?: string; }

// References occupy a standalone Markdown line; examples inside code/quotes stay text.
export function answerReferenceParts(content: string, streaming: boolean = false): AnswerReferencePart[] {
  const parts: AnswerReferencePart[] = [];
  const prefixes = ['[[tinybot-preview:', '[[tinybot-panel:', '[[tinybot-board:'];
  const lines = content.split('\n');
  let text = '', fence = '', fenceLength = 0;
  const flush = (): void => {
    if (text.trim()) { parts.push({ kind: 'text', content: text, previewId: '' }); }
    text = '';
  };
  lines.forEach((line, index) => {
    const delimiter = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (delimiter) {
      if (!fence) { fence = delimiter[1][0]; fenceLength = delimiter[1].length; }
      else if (delimiter[1][0] === fence && delimiter[1].length >= fenceLength && !delimiter[2].trim()) { fence = ''; }
      text += line + (index < lines.length - 1 ? '\n' : ''); return;
    }
    const value = line.trim();
    const block = !fence && !/^( {4}|\t)/.test(line);
    if (block && prefixes.some((prefix) => value.startsWith(prefix))) {
      flush();
      const preview = value.match(/^\[\[tinybot-preview:(pv_[A-Za-z0-9_-]{1,77})\]\]$/);
      const panel = value.match(/^\[\[tinybot-(panel|board):([A-Za-z0-9_-]{1,128})\/([A-Za-z0-9][A-Za-z0-9_-]{0,127})\]\]$/);
      if (preview) { parts.push({ kind: 'preview', content: '', previewId: preview[1] }); }
      else if (panel) { parts.push({ kind: panel[1], content: '', previewId: '', panelKey: panel[2] + '/' + panel[3] }); }
      else if (!streaming) {
        const isPreview = value.startsWith(prefixes[0]);
        parts.push({ kind: isPreview ? 'invalid' : 'invalid-panel', content: isPreview ? 'Invalid preview reference' : 'Invalid Life Panel reference', previewId: '' });
      }
      return;
    }
    if (block && streaming && value.length >= 2 && prefixes.some((prefix) => prefix.startsWith(value))) { flush(); return; }
    text += line + (index < lines.length - 1 ? '\n' : '');
  });
  flush(); return parts;
}
