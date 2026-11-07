// Compatibility discovery for old catalog calls. Authoring documents live in bundled Skills.
interface PanelSkillResource { name: string; path?: string; }
interface PanelSkillIndex { protocol: string; version: number; resources: PanelSkillResource[]; }
export function panelSkillCatalog(section: string = 'all'): string {
  const sections: Record<string, PanelSkillResource[]> = {
    'all': [{ name: 'widget' }, { name: 'widget-design' }, { name: 'canvas' }],
    'design': [{ name: 'widget-design' }],
    'html': [{ name: 'widget' }, { name: 'widget', path: 'references/definition.md' },
      { name: 'widget', path: 'references/runtime.md' }, { name: 'widget', path: 'references/validation.md' },
      { name: 'widget', path: 'assets/counter.html' }, { name: 'widget', path: 'assets/counter.panel.json' }],
    'native': [{ name: 'widget' }, { name: 'widget', path: 'references/native.md' }],
    'sources': [{ name: 'widget' }, { name: 'widget', path: 'references/sources.md' },
      { name: 'widget', path: 'references/transforms.md' }, { name: 'widget', path: 'references/tasks.md' }]
  };
  const resources = sections[section];
  if (!resources) { throw new Error('Catalog section must be all/html/native/sources/design/balance'); }
  return JSON.stringify({ protocol: 'tinybot.life-panel', version: 2, resources: resources } as PanelSkillIndex);
}
