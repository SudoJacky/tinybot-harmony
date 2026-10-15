import { MarkdownBlock } from '../model/Markdown';

export const MARKDOWN_CHUNK_BLOCKS: number = 16;
@Observed
export class MarkdownChunkModel {
  blocks: MarkdownBlock[];
  animate: boolean;
  constructor(blocks: MarkdownBlock[], animate: boolean) { this.blocks = blocks; this.animate = animate; }
  update(blocks: MarkdownBlock[]): void {
    if (blocks.length === this.blocks.length && blocks.every((block, index) => block === this.blocks[index])) { return; }
    this.blocks = blocks;
  }
}
