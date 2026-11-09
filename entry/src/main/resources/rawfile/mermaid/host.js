(() => {
  const diagram = document.getElementById('diagram');
  let latestRevision = 0;
  let displayedRevision = 0;
  let status = 'ok';
  let queue = Promise.resolve();

  function reportSize() {
    if (displayedRevision !== latestRevision || displayedRevision === 0) return;
    document.title = 'mermaid:' + displayedRevision + ':' + Math.ceil(diagram.getBoundingClientRect().height) + ':' + status;
  }

  new ResizeObserver(reportSize).observe(diagram);

  window.renderMermaid = (input) => {
    latestRevision = input.revision;
    queue = queue.then(async () => {
      if (input.revision !== latestRevision) return;
      const stage = document.createElement('div');
      stage.style.cssText = 'position:absolute;inset:0 0 auto;visibility:hidden';
      document.body.append(stage);
      try {
        // Strict mode sanitizes the SVG and disables diagram callbacks. CSP also blocks
        // external resources and inline scripts. Never call the returned bindFunctions.
        mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
          theme: input.dark ? 'dark' : 'default' });
        if (input.source.length > 50000) throw new Error('Diagram exceeds the Mermaid source limit');
        const { svg } = await mermaid.render('tinybot-diagram-' + input.revision, input.source, stage);
        if (input.revision !== latestRevision) return;
        diagram.innerHTML = svg;
        status = 'ok';
      } catch {
        if (input.revision !== latestRevision) return;
        const label = document.createElement('p');
        label.textContent = input.errorLabel;
        const source = document.createElement('pre');
        source.textContent = input.source;
        diagram.replaceChildren(label, source);
        status = 'error';
      } finally {
        stage.remove();
      }
      diagram.classList.toggle('dark', input.dark);
      diagram.classList.toggle('unselectable', !input.selectable);
      displayedRevision = input.revision;
      reportSize();
    });
  };
})();
