// Keep the generic icon visible until a site's optional favicon has actually loaded.
@Component
export struct WebsiteIcon {
  @Prop @Watch('sourceChanged') source: string = '';
  @State private loaded: boolean = false;
  @State private failed: boolean = false;

  sourceChanged(): void { this.loaded = false; this.failed = false; }

  build() {
    Stack() {
      SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(13)
        .fontColor([$r('app.color.text_tertiary')]).opacity(this.loaded ? 0 : 1)
      if (this.source && !this.failed) {
        Image(this.source).width(14).height(14).objectFit(ImageFit.Contain)
          .opacity(this.loaded ? 1 : 0)
          .onComplete(() => { this.loaded = true; })
          .onError(() => { this.loaded = false; this.failed = true; })
      }
    }.width(14).height(14).accessibilityLevel('no')
  }
}
