import { MarkdownBlock } from '../model/Markdown';

export const MARKDOWN_CHUNK_BLOCKS: number = 16;
@Observed
export class MarkdownChunkModel {
  blocks: MarkdownBlock[];
  constructor(blocks: MarkdownBlock[]) { this.blocks = blocks; }
  update(blocks: MarkdownBlock[]): void {
    if (blocks.length === this.blocks.length && blocks.every((block, index) => block === this.blocks[index])) { return; }
    this.blocks = blocks;
  }
}
