import { BUILTIN_SKILL_DOCUMENTS, BuiltinSkillDocument } from './BuiltinSkillCatalog';
import { ExtensionSettings, MAX_SKILL_TOTAL, SkillData, SkillFile, parseSkill, validateExtensions } from './Skills';

// Length and FNV-1a over UTF-16 code units for the shipped LF-normalized documents.
const RETIRED_BUILTIN_VERSIONS: Map<string, string[]> = new Map<string, string[]>([
  ['document-brief', ['707:3373612214', '642:1415657932', '615:2832046145', '607:4005130047']],
  ['web-research', ['587:242030950']],
  ['notes-to-actions', ['614:1097566947']],
  ['data-analysis', ['1265:1195935071', '1261:2884379493', '831:3595493593', '781:461599382']]
]);

export function isRetiredBuiltinSkill(skill: SkillData, seeded: string[]): boolean {
  const versions = RETIRED_BUILTIN_VERSIONS.get(skill.name);
  if (!versions || !seeded.includes(skill.name) || skill.source || skill.files.length > 0) { return false; }
  let hash = 2166136261;
  for (let index = 0; index < skill.document.length; index++) {
    hash = Math.imul(hash ^ skill.document.charCodeAt(index), 16777619);
  }
  return versions.includes(skill.document.length + ':' + (hash >>> 0));
}

// Called on the detached startup snapshot. Persist the installation record with the documents.
// Editing, disabling, renaming or deleting a seeded Skill must survive subsequent starts.
export function seedBuiltinSkills(settings: ExtensionSettings): boolean {
  validateExtensions(settings);
  const seeded = (settings.seededBuiltinSkills || []).slice();
  const remaining = settings.skills.filter((skill) => !isRetiredBuiltinSkill(skill, seeded));
  let changed = remaining.length !== settings.skills.length;
  if (changed) { settings.skills = remaining; }
  let total = settings.skills.reduce((sum, skill) => sum + skill.document.length +
    skill.files.reduce((size, file) => size + file.content.length, 0), 0);
  for (const entry of BUILTIN_SKILL_DOCUMENTS) {
    if (seeded.includes(entry.name)) { continue; }
    if (!settings.skills.some((skill) => skill.name === entry.name)) {
      const size = entry.document.length + entry.files.reduce((sum, file) => sum + file.content.length, 0);
      // Leave pending entries available for a later start when the user has freed capacity.
      if (total + size > MAX_SKILL_TOTAL) { continue; }
      const skill = parseSkill(entry.document);
      skill.files = entry.files.map((file): SkillFile => ({ path: file.path, content: file.content }));
      settings.skills.push(skill); total += size;
    }
    seeded.push(entry.name); changed = true;
  }
  if (changed) { settings.seededBuiltinSkills = seeded; }
  validateExtensions(settings);
  return changed;
}

// A changed or replaced document becomes a user copy, rather than claiming bundled provenance.
export function builtinSkillInfo(skill: SkillData): BuiltinSkillDocument | undefined {
  return BUILTIN_SKILL_DOCUMENTS.find((entry) => entry.name === skill.name && entry.document === skill.document &&
    JSON.stringify(entry.files) === JSON.stringify(skill.files) && !skill.source);
}
