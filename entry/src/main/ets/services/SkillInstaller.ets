import { SkillData, SkillFile, parseSkill, skillPath, validateExtensions, MAX_SKILL_TEXT } from '../model/Skills';
import { Cancellation } from './Cancellation';
import { WebTransport } from './WebTools';

interface GithubEntry { type: string; path: string; name: string; download_url?: string; }
interface GithubRepo { default_branch: string; }

// Fetch bytes through the transport's strict decoder, never through read_web's extraction/truncation.
export class SkillInstaller {
  private transport: WebTransport;
  constructor(transport: WebTransport) { this.transport = transport; }
  private secure(address: string): string {
    if (typeof address !== 'string' || address.length > 2048 || !/^https:\/\/[^\s/?#@\\]+(?:\/[^\s#\\]*)?$/.test(address)) {
      throw new Error('Skill sources must be HTTPS URLs without credentials or fragments.');
    }
    return address;
  }
  private async text(address: string, cancellation: Cancellation): Promise<string> {
    const result = await this.transport.get(this.secure(address), cancellation); this.secure(result.url);
    if (/html|octet-stream|image\//i.test(result.contentType) || result.body.includes('\u0000') || result.body.length > MAX_SKILL_TEXT) {
      throw new Error('Skill files must be text, at most 32000 characters: ' + address);
    }
    return result.body;
  }
  async install(source: string, paths: string[], cancellation: Cancellation): Promise<SkillData> {
    this.secure(source);
    if (!Array.isArray(paths) || paths.length > 16 || new Set(paths).size !== paths.length) { throw new Error('Provide at most 16 distinct reference paths.'); }
    for (const path of paths) { skillPath(path); if (path === 'SKILL.md' || /[%?#]/.test(path)) { throw new Error('Invalid reference path: ' + path); } }
    let address = source;
    const github = /^https:\/\/github\.com\/([^/]+)\/([^/?]+)(?:\/(tree|blob)\/([^/]+)\/(.+))?\/?$/.exec(source);
    let files: SkillFile[] = [];
    let document = '';
    if (github && github[3] !== 'blob') {
      const repository = github[1] + '/' + github[2];
      const ref = github[4] || (JSON.parse((await this.transport.get('https://api.github.com/repos/' + repository, cancellation)).body) as GithubRepo).default_branch;
      if (!ref) { throw new Error('GitHub repository did not return a default branch.'); }
      const folder = (github[5] || '').replace(/\/$/, '');
      const entries: GithubEntry[] = [];
      await this.directory(repository, ref, folder, entries, cancellation);
      const main = entries.find((item) => item.path === (folder ? folder + '/' : '') + 'SKILL.md');
      if (!main?.download_url) { throw new Error('Choose a GitHub directory containing SKILL.md.'); }
      document = await this.text(main.download_url, cancellation);
      for (const entry of entries) {
        if (entry === main) { continue; }
        const path = entry.path.slice(folder ? folder.length + 1 : 0); skillPath(path);
        if (!entry.download_url) { throw new Error('GitHub file has no download URL: ' + path); }
        files.push({ path: path, content: await this.text(entry.download_url, cancellation) });
      }
      for (const path of paths) { if (!files.some((item) => item.path === path)) { throw new Error('Reference is missing: ' + path); } }
    } else {
      if (github) { address = 'https://raw.githubusercontent.com/' + github[1] + '/' + github[2] + '/' + github[4] + '/' + github[5]; }
      if (!/\/SKILL\.md(?:\?[^#]*)?$/.test(address)) { throw new Error('Use an HTTPS SKILL.md URL or a GitHub skill directory.'); }
      document = await this.text(address, cancellation);
      for (const path of paths) {
        files.push({ path: path, content: await this.text(this.transport.resolve(path.split('/').map((part) => encodeURIComponent(part)).join('/'), address), cancellation) });
      }
    }
    const skill = parseSkill(document); skill.files = files;
    skill.source = { url: source, installedAt: Date.now(), modified: false };
    validateExtensions({ webEnabled: true, skills: [skill] }); cancellation.check(); return skill;
  }
  private async directory(repository: string, ref: string, folder: string, entries: GithubEntry[], cancellation: Cancellation, depth: number = 0): Promise<void> {
    if (depth > 4) { throw new Error('Skill directories may be at most 4 levels deep.'); }
    const response = await this.transport.get('https://api.github.com/repos/' + repository + '/contents/' +
      folder.split('/').map((part) => encodeURIComponent(part)).join('/') + '?ref=' + encodeURIComponent(ref), cancellation);
    const items = JSON.parse(response.body) as GithubEntry[];
    if (!Array.isArray(items) || items.length > 17) { throw new Error('Skill directory is not a bounded text bundle (max 17 files).'); }
    for (const item of items) {
      if (!item || typeof item.path !== 'string' || !item.path.startsWith(folder ? folder + '/' : '') || item.path.slice(folder ? folder.length + 1 : 0).includes('/')) {
        throw new Error('Invalid GitHub directory entry.');
      }
      if (item.type === 'dir') { await this.directory(repository, ref, item.path, entries, cancellation, depth + 1); }
      else if (item.type === 'file') { entries.push(item); if (entries.length > 17) { throw new Error('Skill has more than 16 reference files.'); } }
      else { throw new Error('Skill contains a symlink or unsupported repository entry: ' + item.path); }
    }
  }
}
