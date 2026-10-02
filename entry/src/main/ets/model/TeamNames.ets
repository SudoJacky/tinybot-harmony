// Fallback identities are chosen once at recruitment and persisted as TeamMember.name.
// UI language changes must never rename an existing employee.
const ZH_NAMES: string[] = ['林知夏', '陈亦舟', '沈星禾', '许景行', '苏沐言', '顾清和', '周予安', '陆明远'];
const EN_NAMES: string[] = ['Alex Chen', 'Jamie Lin', 'Sam Rivers', 'Robin Lee', 'Taylor Morgan', 'Casey Park', 'Jordan Ellis', 'Avery Quinn'];

export function employeeName(id: string, locale: string, reserved: string[]): string {
  const names = locale === 'zh-CN' ? ZH_NAMES : EN_NAMES;
  let hash = 0;
  for (let index = 0; index < id.length; index++) { hash = (hash * 31 + id.charCodeAt(index)) >>> 0; }
  const used = new Set(reserved.map((name: string) => name.trim().toLowerCase()));
  for (let offset = 0; offset < names.length; offset++) {
    const name = names[(hash + offset) % names.length];
    if (!used.has(name.toLowerCase())) { return name; }
  }
  const base = names[hash % names.length];
  let suffix = 2;
  while (used.has((base + ' ' + suffix).toLowerCase())) { suffix++; }
  return base + ' ' + suffix;
}
