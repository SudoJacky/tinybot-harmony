import { MarkdownSpan } from './Markdown';

interface CodeLanguage {
  names: string;
  keywords: string;
  literals: string;
  comments: string;
  strings: string;
}

const QUOTED: string = '"(?:\\\\.|[^"\\\\\\r\\n])*(?:"|$)|\'(?:\\\\.|[^\'\\\\\\r\\n])*(?:\'|$)';
const C_COMMENTS: string = '//[^\\n]*|/\\*[\\s\\S]*?(?:\\*/|$)';
const SCRIPT_KEYWORDS: string = 'as async await break case catch class const continue debugger declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface keyof let namespace new of private protected public readonly return satisfies set static struct super switch this throw try type typeof var void while with yield';
const LANGUAGES: CodeLanguage[] = [
  { names: 'javascript js jsx typescript ts tsx arkts ets', keywords: SCRIPT_KEYWORDS,
    literals: 'true false null undefined NaN Infinity', comments: C_COMMENTS,
    strings: QUOTED + '|`(?:\\\\.|[^`\\\\])*(?:`|$)' },
  { names: 'python py', keywords: 'and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield',
    literals: 'True False None', comments: '#[^\\n]*',
    strings: '"""[\\s\\S]*?(?:"""|$)|\'\'\'[\\s\\S]*?(?:\'\'\'|$)|' + QUOTED },
  { names: 'c h cpp c++ cc cxx hpp java kotlin kt csharp cs c# swift go golang rust rs',
    keywords: 'abstract as async await auto bool boolean break byte case catch char class const constexpr continue crate default defer do double dyn else enum explicit extern final finally float fn for func fun go if impl implements import in inline int interface internal is let long match mod move mut namespace native new null object operator override package private protected pub public ref register return sealed self Self short signed sizeof static string String struct super switch synchronized template this throw throws trait try type typedef typename uint union unsigned use using val var virtual void volatile when where while with',
    literals: 'true false null nil nullptr None Some', comments: C_COMMENTS,
    strings: QUOTED + '|`[^`]*(?:`|$)' },
  { names: 'json jsonc', keywords: '', literals: 'true false null', comments: '',
    strings: '"(?:\\\\.|[^"\\\\\\r\\n])*(?:"|$)' },
  { names: 'bash sh shell zsh', keywords: 'if then else elif fi for while until do done in case esac function select time export local readonly return break continue source',
    literals: 'true false', comments: '#[^\\n]*', strings: QUOTED + '|`[^`]*(?:`|$)' },
  { names: 'sql', keywords: 'select from where insert into values update set delete create alter drop table index view join left right inner outer full cross on as and or not null is in exists between like union all distinct group by having order asc desc limit offset case when then else end with recursive primary foreign key references constraint default begin commit rollback returning count sum avg min max',
    literals: 'true false null', comments: '--[^\\n]*|/\\*[\\s\\S]*?(?:\\*/|$)',
    strings: "'(?:''|[^'])*(?:'|$)|\"(?:\"\"|[^\"])*(?:\"|$)" },
  { names: 'yaml yml', keywords: '', literals: 'true false null yes no on off',
    comments: '#[^\\n]*', strings: QUOTED },
  { names: 'html xml svg', keywords: '', literals: '', comments: '<!--[\\s\\S]*?(?:-->|$)', strings: QUOTED },
  { names: 'css scss', keywords: 'important inherit initial unset auto none', literals: '',
    comments: '/\\*[\\s\\S]*?(?:\\*/|$)', strings: QUOTED }
];
const NUMBER: string = '\\b(?:0[xX][\\da-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.[\\d_]+)?(?:[eE][+-]?[\\d_]+)?)\\b';

function append(spans: MarkdownSpan[], text: string, kind: string): void {
  if (!text) { return; }
  const last = spans[spans.length - 1];
  if (last && last.kind === kind) { last.text += text; }
  else { spans.push({ text: text, kind: kind, url: '' }); }
}

// Pure lexical highlighting: preserve every character, including unfinished streamed
// tokens. An absent/unknown fence language intentionally remains plain code.
export function highlightCode(text: string, info: string): MarkdownSpan[] {
  const name = info.trim().toLowerCase().split(/\s+/)[0];
  const language = LANGUAGES.find((item: CodeLanguage) => item.names.split(' ').includes(name));
  if (!language) { return text ? [{ text: text, kind: 'text', url: '' }] : []; }
  const json = name === 'json' || name === 'jsonc';
  const markup = language.names === 'html xml svg';
  const css = language.names === 'css scss';
  const comments = name === 'jsonc' ? C_COMMENTS : language.comments;
  // Each alternative owns one capture; the component patterns use non-capturing groups.
  const words = markup ? '</?[A-Za-z][\\w:.-]*|[A-Za-z_:][\\w:.-]*(?=\\s*=)' :
    css ? '#[\\da-fA-F]{3,8}\\b|--?[a-zA-Z_][\\w-]*|[a-zA-Z_][\\w-]*' : '[a-zA-Z_$][\\w$]*';
  const pattern = new RegExp('(' + (comments || '(?!)') + ')|(' + language.strings + ')|(' + NUMBER +
    ')|(' + words + ')|([{}\\[\\]();,.?:+*/%=!<>&|~^@-])', 'g');
  const keywords = language.keywords.split(' ');
  const literals = language.literals.split(' ');
  const spans: MarkdownSpan[] = [];
  let offset = 0;
  let match = pattern.exec(text);
  while (match) {
    append(spans, text.slice(offset, match.index), 'text');
    const token = match[0];
    const end = match.index + token.length;
    let kind = 'text';
    if (match[1] !== undefined) { kind = 'syntax-comment'; }
    else if (match[2] !== undefined) {
      kind = json && /^\s*:/.test(text.slice(end)) ? 'syntax-property' : 'syntax-string';
    } else if (match[3] !== undefined) { kind = 'syntax-number'; }
    else if (match[4] !== undefined) {
      const word = name === 'sql' ? token.toLowerCase() : token;
      if (literals.includes(word)) { kind = 'syntax-number'; }
      else if (keywords.includes(word) || (markup && token.startsWith('<'))) { kind = 'syntax-keyword'; }
      else if (markup || ((json || name === 'yaml' || name === 'yml' || css) && /^\s*:/.test(text.slice(end)))) {
        kind = 'syntax-property';
      } else if (css && token.startsWith('#')) { kind = 'syntax-number'; }
      else if (!json && !css && /^\s*\(/.test(text.slice(end))) { kind = 'syntax-function'; }
    } else { kind = 'syntax-punctuation'; }
    append(spans, token, kind);
    offset = end;
    match = pattern.exec(text);
  }
  append(spans, text.slice(offset), 'text');
  return spans;
}
