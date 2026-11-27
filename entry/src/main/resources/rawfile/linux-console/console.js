(() => {
  'use strict';

  const surface = document.getElementById('terminal');
  const terminal = new window.Terminal({
    theme: {
      background: '#171b24',
      foreground: '#e4e9f2',
      cursor: '#a5c9ff',
      cursorAccent: '#171b24',
      selectionBackground: '#3d5777',
      black: '#242b38',
      red: '#ef8d8d',
      green: '#a1d2a9',
      yellow: '#ebc787',
      blue: '#a5c9ff',
      magenta: '#cfabec',
      cyan: '#99d5db',
      white: '#e4e9f2',
    },
    fontFamily: '"DejaVu Sans Mono", "Courier New", monospace',
    fontSize: 14,
    lineHeight: 1.2,
    cursorStyle: 'bar',
    scrollback: 3000,
    disableStdin: true,
    linkHandler: { activate() {} },
  });
  const fit = new window.FitAddon.FitAddon();
  terminal.loadAddon(fit);
  terminal.parser.registerOscHandler(52, () => true);
  terminal.open(surface);

  let layoutFrame = 0;
  const host = () => window.tinybotConsoleHost;
  const reportSize = () => host().consoleSize(terminal.cols, terminal.rows);
  function scheduleFit() {
    if (layoutFrame) return;
    layoutFrame = requestAnimationFrame(() => {
      layoutFrame = 0;
      if (surface.clientWidth > 0 && surface.clientHeight > 0) {
        fit.fit();
        reportSize();
      }
    });
  }

  if ('ResizeObserver' in window) {
    new ResizeObserver(scheduleFit).observe(surface);
  } else {
    window.addEventListener('resize', scheduleFit);
  }
  terminal.onData((text) => host().consoleInput(text));

  window.tinybotTerminal = {
    configure(label, language) {
      document.documentElement.lang = language;
      surface.setAttribute('aria-label', label);
      terminal.textarea?.setAttribute('aria-label', label);
      scheduleFit();
    },
    write(encoded, receipt) {
      const raw = atob(encoded);
      const bytes = Uint8Array.from(raw, (char) => char.charCodeAt(0));
      terminal.write(bytes, () => host().consoleWritten(receipt));
    },
    setConnected(connected) {
      terminal.options.disableStdin = !connected;
      if (connected) scheduleFit();
    },
    reset() {
      terminal.options.disableStdin = true;
      terminal.reset();
      scheduleFit();
    },
    key(name) {
      const keys = { esc: '\x1b', tab: '\t', interrupt: '\x03' };
      const arrows = { up: 'A', down: 'B', right: 'C', left: 'D' };
      const prefix = terminal.modes.applicationCursorKeysMode ? '\x1bO' : '\x1b[';
      const data = keys[name] ?? (arrows[name] ? prefix + arrows[name] : '');
      if (data && !terminal.options.disableStdin) {
        host().consoleInput(data);
        terminal.focus();
      }
    },
    copy() {
      host().consoleCopy(terminal.getSelection());
    },
    paste(text) {
      if (terminal.options.disableStdin) return;
      terminal.paste(text);
      terminal.focus();
    },
  };
})();
