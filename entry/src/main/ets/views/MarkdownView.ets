import { Diagnostics } from '../model/Diagnostics';
import { MarkdownBlock, MarkdownDocument } from '../model/Markdown';
import { MARKDOWN_CHUNK_BLOCKS, MarkdownChunkModel } from '../viewmodel/MarkdownChunkModel';
import { MarkdownChunkView } from './MarkdownChunkView';

@Component
export struct MarkdownView {
  @StorageProp('tinybot.foreground') private foreground: boolean = true;
  @Prop @Watch('refresh') content: string = '';
  @Prop @Watch('refresh') streaming: boolean = false;
  @Prop fontSize: number = 16;
  @Prop selectable: boolean = true;
  @State private chunks: MarkdownChunkModel[] = [];
  private perfId: number = Diagnostics.nextId();
  private blocks: MarkdownBlock[] = [];
  private document: MarkdownDocument = new MarkdownDocument();
  private mounted: boolean = false;
  private renderTimer: number = -1;
  aboutToAppear(): void { Diagnostics.adjust('render.documents', 1); this.refresh(); this.mounted = true; }
  aboutToDisappear(): void { Diagnostics.adjust('render.documents', -1); this.mounted = false; clearTimeout(this.renderTimer); this.renderTimer = -1; }
  private refresh(): void {
    const mark = Diagnostics.begin(this.perfId);
    const update = this.document.update(this.content);
    if (Diagnostics.recording) {
      Diagnostics.measure('markdown.sourceChars', this.content.length, 'UTF16');
      Diagnostics.end('markdown.parse', mark, { sourceChars: this.content.length, changedBlocks: update.blocks.length, startBlock: update.start });
    }
    if (!update.blocks.length && update.start === this.blocks.length) {
      if (this.renderTimer === -1) { this.syncChunks(this.chunks.length); }
      return;
    }
    const next = update.blocks.map((block: MarkdownBlock, offset: number): MarkdownBlock => {
      const previous = this.blocks[update.start + offset];
      return previous && previous.kind === block.kind && previous.text === block.text && previous.level === block.level &&
        JSON.stringify(previous.rows) === JSON.stringify(block.rows) ? previous : block;
    });
    this.blocks.splice(update.start, this.blocks.length - update.start, ...next);
    this.syncChunks(Math.floor(update.start / MARKDOWN_CHUNK_BLOCKS));
  }
  private syncChunks(start: number): void {
    const mark = Diagnostics.begin(this.perfId);
    const previous = this.chunks.length;
    start = Math.min(start, this.chunks.length);
    const count = Math.ceil(this.blocks.length / MARKDOWN_CHUNK_BLOCKS);
    // Bound first-mount work even when an entire long answer arrives in one chunk.
    const end = Math.min(count, this.chunks.length + Math.max(1, Math.floor(32 / MARKDOWN_CHUNK_BLOCKS)));
    for (let index = start; index < end; index++) {
      const blocks = this.blocks.slice(index * MARKDOWN_CHUNK_BLOCKS, (index + 1) * MARKDOWN_CHUNK_BLOCKS);
      if (index < this.chunks.length) { this.chunks[index].update(blocks); }
      else { this.chunks.push(new MarkdownChunkModel(blocks, this.mounted && this.streaming)); }
    }
    if (this.chunks.length > count) { this.chunks.splice(count); }
    if (Diagnostics.recording) { Diagnostics.end('render.mountBatch', mark, { newChunks: this.chunks.length - previous, mountedChunks: this.chunks.length, totalChunks: count }); }
    if (this.chunks.length < count && this.renderTimer === -1) {
      this.renderTimer = setTimeout(() => {
        this.renderTimer = -1;
        if (this.mounted) { this.syncChunks(this.chunks.length); }
      }, 16);
    }
  }
  build() {
    Column({ space: 10 }) {
      ForEach(this.chunks, (chunk: MarkdownChunkModel, index: number) => {
        MarkdownChunkView({ model: chunk, blockOffset: index * MARKDOWN_CHUNK_BLOCKS, streaming: this.streaming && this.foreground,
          fontSize: this.fontSize, selectable: this.selectable })
      }, (_chunk: MarkdownChunkModel, index: number) => `${index}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
