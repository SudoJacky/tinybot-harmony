import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';

const MATCH_WINDOW: number = 64;
export const OUTPUT_WORD_LIST: string = 'moderation/wechat-ime-2026-11-07.txt';

// A one-to-one fold keeps match positions valid in the original streamed text.
function fold(unit: number): number {
  if (unit >= 0xff01 && unit <= 0xff5e) { unit -= 0xfee0; }
  return unit >= 65 && unit <= 90 ? unit + 32 : unit;
}

class WordNode {
  readonly edges: Map<number, number> = new Map<number, number>();
  readonly matches: number[] = [];
  readonly depth: number;
  failure: number = 0;
  prefix: number = 0;

  constructor(depth: number) { this.depth = depth; }
}

export class OutputWordMatcher {
  private readonly nodes: WordNode[] = [new WordNode(0)];

  constructor(source: string) {
    for (const line of source.split('\n')) {
      const word = line.trim();
      if (!word || word.startsWith('#')) { continue; }
      let state = 0;
      for (let i = 0; i < word.length; i++) {
        const unit = fold(word.charCodeAt(i));
        const node = this.nodes[state];
        let next = node.edges.get(unit);
        if (next === undefined) {
          next = this.nodes.length;
          node.edges.set(unit, next);
          this.nodes.push(new WordNode(node.depth + 1));
        }
        state = next;
      }
      if (!this.nodes[state].matches.length) { this.nodes[state].matches.push(state); }
    }
    if (this.nodes.length === 1) { throw new Error('The packaged output word list is empty.'); }

    const queue = Array.from(this.nodes[0].edges.values());
    for (let i = 0; i < queue.length; i++) {
      const node = this.nodes[queue[i]];
      const fallback = this.nodes[node.failure];
      node.matches.push(...fallback.matches);
      node.prefix = node.edges.size > 0 ? node.depth : fallback.prefix;
      node.edges.forEach((child, unit) => {
        this.nodes[child].failure = this.advance(node.failure, unit);
        queue.push(child);
      });
    }
  }

  advance(state: number, unit: number): number {
    const key = fold(unit);
    while (state !== 0 && !this.nodes[state].edges.has(key)) { state = this.nodes[state].failure; }
    return this.nodes[state].edges.get(key) ?? 0;
  }

  matches(state: number): number[] { return this.nodes[state].matches; }
  length(word: number): number { return this.nodes[word].depth; }
  prefixLength(state: number): number { return this.nodes[state].prefix; }
}

interface WordHit { word: number; start: number; end: number; }
type OutputChannel = 'answer' | 'reasoning';

export class OutputWordGuardStop extends Error {
  constructor() { super(t('回复已因内容审核停止。')); }
}

export class OutputWordGuard {
  private readonly matcher: OutputWordMatcher;
  private readonly publish: (text: string) => void;
  private readonly channel: OutputChannel;
  private readonly hits: WordHit[] = [];
  private state: number = 0;
  private position: number = 0;
  private published: number = 0;
  private received: string = '';

  constructor(matcher: OutputWordMatcher, channel: OutputChannel, publish: (text: string) => void) {
    this.matcher = matcher;
    this.channel = channel;
    this.publish = publish;
  }

  push(text: string): void {
    this.received += text;
    while (this.position < this.received.length) {
      this.state = this.matcher.advance(this.state, this.received.charCodeAt(this.position));
      const end = ++this.position;
      const cutoff = end - MATCH_WINDOW;
      while (this.hits.length && this.hits[0].end <= cutoff) { this.hits.shift(); }
      for (const word of this.matcher.matches(this.state)) {
        const start = end - this.matcher.length(word);
        if (this.hits.some((hit) => hit.word !== word && hit.end <= start && hit.start >= cutoff)) {
          this.release(start);
          Diagnostics.log('warn', 'moderation', 'output_words_stopped', { channel: this.channel, count: 2 });
          throw new OutputWordGuardStop();
        }
        this.hits.push({ word: word, start: start, end: end });
      }
    }
    // Only a prefix of a possible second, non-overlapping hit can affect output.
    const first = this.hits[0];
    const safe = first ? Math.max(first.end, this.position - this.matcher.prefixLength(this.state)) : this.position;
    this.release(safe);
  }

  finish(text: string): void {
    if (!this.received) { this.push(text); }
    if (this.received !== text) { throw new Error(t('模型最终文本与流式片段不一致。')); }
    this.release(this.position);
  }

  private release(end: number): void {
    if (end <= this.published) { return; }
    const text = this.received.slice(this.published, end);
    this.published = end;
    this.publish(text);
  }
}
