import { BUILTIN_SKILL_DOCUMENTS, BuiltinSkillDocument } from './BuiltinSkillCatalog';
import { ExtensionSettings, MAX_SKILLS, MAX_SKILL_TOTAL, SkillData, SkillFile, parseSkill, validateExtensions } from './Skills';

// Called on the detached startup snapshot. Persist the installation record with the documents.
// Editing, disabling, renaming or deleting a seeded Skill must survive subsequent starts.
export function seedBuiltinSkills(settings: ExtensionSettings): boolean {
  validateExtensions(settings);
  const seeded = (settings.seededBuiltinSkills || []).slice();
  let changed = false;
  let total = settings.skills.reduce((sum, skill) => sum + skill.document.length +
    skill.files.reduce((size, file) => size + file.content.length, 0), 0);
  for (const entry of BUILTIN_SKILL_DOCUMENTS) {
    if (seeded.includes(entry.name)) { continue; }
    if (!settings.skills.some((skill) => skill.name === entry.name)) {
      const size = entry.document.length + entry.files.reduce((sum, file) => sum + file.content.length, 0);
      // Leave pending entries available for a later start when the user has freed capacity.
      if (settings.skills.length >= MAX_SKILLS || total + size > MAX_SKILL_TOTAL) { continue; }
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
