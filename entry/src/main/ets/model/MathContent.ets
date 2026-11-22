import { MarkdownSpan, markdownSpans } from './Markdown';

export function hasMath(text: string): boolean {
  return (text.includes('$') || text.includes('\\(')) && markdownSpans(text).some((span: MarkdownSpan) => span.kind === 'math');
}
export interface MathDimensions {
  width: number;
  height: number;
  descent: number;
}

export interface MathDrawing extends MathDimensions {
  svg: string;
}

export interface MathRequest {
  tex: string;
  display: boolean;
  color: string;
  path: string;
}

export interface MathResponse extends MathDimensions {
  bytes: number;
  error?: string;
}
