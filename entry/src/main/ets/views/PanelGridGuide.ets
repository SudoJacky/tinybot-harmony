@Component
export struct PanelGridGuide {
  @Prop @Watch('draw') step: number = 30;
  @Prop @Watch('draw') rowStep: number = 44;
  @Prop @Watch('draw') scrollY: number = 0;
  @Prop @Watch('draw') heightVp: number = 500;
  @Prop @Watch('draw') color: string = '#20246959';
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private draw(): void {
    if (!this.ready || this.step <= 0 || this.rowStep <= 0) { return; }
    const width = this.canvas.width, height = this.canvas.height;
    this.canvas.clearRect(0, 0, width, height); this.canvas.strokeStyle = this.color; this.canvas.lineWidth = 1;
    this.canvas.beginPath();
    for (let x = 0; x <= width; x += this.step) { this.canvas.moveTo(x, 0); this.canvas.lineTo(x, height); }
    for (let y = -(this.scrollY % this.rowStep); y <= height; y += this.rowStep) { this.canvas.moveTo(0, y); this.canvas.lineTo(width, y); }
    this.canvas.stroke();
  }
  build() {
    Canvas(this.canvas).width('100%').height(this.heightVp).onReady(() => { this.ready = true; this.draw(); })
      .onAreaChange(() => this.draw()).accessibilityLevel('no')
  }
}
