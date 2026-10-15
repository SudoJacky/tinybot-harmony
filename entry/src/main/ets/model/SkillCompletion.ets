import { builtinSkillInfo } from './BuiltinSkills';
import { t } from './I18n';
import { SkillData } from './Skills';

export interface SkillQuery { start: number; end: number; text: string; }
export interface SkillDraft { text: string; caret: number; }

export function skillQuery(text: string, caret: number = text.length): SkillQuery | undefined {
  if (!Number.isInteger(caret) || caret < 0 || caret > text.length) { return undefined; }
  const match = /(^|\s)\$([^\s$]*)$/.exec(text.slice(0, caret));
  // A word boundary avoids prices such as US$20; a numeric prefix keeps $20 ordinary text.
  if (!match || (match[2] && !/^[a-zA-Z\u3400-\u9fff]/.test(match[2]))) { return undefined; }
  const tail = /^[^\s$]*/.exec(text.slice(caret))?.[0] || '';
  return { start: match.index + match[1].length, end: caret + tail.length, text: match[2] };
}

export function skillDisplayName(skill: SkillData): string {
  const builtin = builtinSkillInfo(skill);
  return builtin ? t(builtin.title) : skill.name;
}

export function matchingSkills(skills: SkillData[], query: string): SkillData[] {
  const search = query.toLowerCase();
  return skills.filter((skill) => skill.enabled && [skill.name, skillDisplayName(skill),
    builtinSkillInfo(skill) ? t(skill.description) : skill.description].some((value) => value.toLowerCase().includes(search)));
}

// Keep the existing single-Skill command and stored expansion semantics for every entry point.
export function skillDraft(text: string, name: string, query?: SkillQuery): SkillDraft {
  let body = text;
  let caret = text.length;
  if (query) {
    let suffix = text.slice(query.end);
    const prefix = text.slice(0, query.start);
    if (prefix.endsWith(' ') && suffix.startsWith(' ')) { suffix = suffix.slice(1); }
    body = prefix + suffix; caret = prefix.length;
  }
  const command = /^\/skill:[^\s]+\s*/.exec(body)?.[0] || '';
  body = body.slice(command.length); caret = Math.max(0, caret - command.length);
  if (query) {
    const whitespace = /^\s*/.exec(body)?.[0].length || 0;
    body = body.slice(whitespace); caret = Math.max(0, caret - whitespace);
  }
  const prefix = '/skill:' + name + ' ';
  return { text: prefix + body, caret: prefix.length + caret };
}
