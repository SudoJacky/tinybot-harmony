import { UiScene, UiShape, parseUiScene } from '../model/UiScene';
import { Btn } from '../common/Theme';
// Declarative vectors, never arbitrary drawing scripts. Controls remain accessible native buttons.
@Component
export struct UiSceneView {
  @Prop @Watch('refresh') content: string = '';
  @Prop interactive: boolean = false;
  onAction: (id: string) => void = () => {};
  @State private scene: UiScene = { width: 400, height: 240, shapes: [] };
  @State private error: string = '';
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private canvasWidth: number = 300;
  private ready: boolean = false;
  aboutToAppear(): void { this.refresh(); }
  private refresh(): void {
    try { this.scene = parseUiScene(this.content); this.error = ''; if (this.ready) { this.draw(); } }
    catch (error) { this.error = (error as Error).message; }
  }
  private controls(): UiShape[] { return this.scene.shapes.filter((shape) => !!shape.action); }
  private draw(): void {
    const ctx = this.canvas; const scale = this.canvasWidth / this.scene.width;
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasWidth * this.scene.height / this.scene.width);
    ctx.save(); ctx.scale(scale, scale);
    for (const shape of this.scene.shapes) {
      ctx.fillStyle = shape.color || '#2468c8'; ctx.strokeStyle = shape.color || '#2468c8'; ctx.lineWidth = 2;
      ctx.beginPath();
      if (shape.kind === 'rect') { ctx.fillRect(shape.x, shape.y, shape.width || 0, shape.height || 0); }
      else if (shape.kind === 'circle') { ctx.arc(shape.x, shape.y, shape.radius || 0, 0, Math.PI * 2); ctx.fill(); }
      else if (shape.kind === 'line') { ctx.moveTo(shape.x, shape.y); ctx.lineTo(shape.x2 || 0, shape.y2 || 0); ctx.stroke(); }
      else { ctx.font = '16px sans-serif'; ctx.textBaseline = 'top'; ctx.fillText(shape.text || '', shape.x, shape.y, this.scene.width - shape.x); }
    }
    ctx.restore();
  }
  build() {
    Column({ space: 8 }) {
      if (this.error) { Text(this.error).fontColor($r('app.color.danger')) }
      else {
        Canvas(this.canvas).width('100%').aspectRatio(this.scene.width / this.scene.height).backgroundColor('#ffffff')
          .accessibilityText(this.scene.shapes.map((shape: UiShape) => shape.text || '').filter((label: string) => !!label).join(', '))
          .onReady(() => { this.ready = true; this.draw(); })
          .onAreaChange((_old, area) => { this.canvasWidth = Number(area.width); if (this.ready) { this.draw(); } })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.controls(), (shape: UiShape) => {
            Button(shape.text || shape.id).attributeModifier(Btn.tonalSmall).margin(4).enabled(this.interactive)
              .onClick(() => this.onAction(shape.action || ''))
          }, (shape: UiShape) => shape.id)
        }.width('100%')
      }
    }.width('100%')
  }
}
