(() => {
  'use strict';

  const surface = document.getElementById('terminal');
  const latest = document.getElementById('latest');
  const terminal = new window.Terminal({
    theme: {
      background: '#1c1e20',
      foreground: '#f2f0eb',
      cursor: '#fff3db',
      cursorAccent: '#1c1e20',
      selectionBackground: '#3d5777',
      black: '#242b38',
      red: '#ef8d8d',
      green: '#88dd9d',
      yellow: '#ebc787',
      blue: '#a5c9ff',
      magenta: '#cfabec',
      cyan: '#99d5db',
      white: '#e4e9f2',
    },
    fontFamily: '"DejaVu Sans Mono", "Courier New", monospace',
    fontSize: 12,
    lineHeight: 1,
    cursorStyle: 'block',
    cursorInactiveStyle: 'block',
    scrollback: 3000,
    disableStdin: true,
    linkHandler: { activate() {} },
  });
  const fit = new window.FitAddon.FitAddon();
  terminal.loadAddon(fit);
  terminal.parser.registerOscHandler(52, () => true);
  let writingHistory = false;
  // Replaying a past cursor or device query must not send a second reply to the shell.
  terminal.parser.registerCsiHandler({ final: 'n' }, () => writingHistory);
  terminal.parser.registerCsiHandler({ final: 'c' }, () => writingHistory);
  terminal.open(surface);

  let layoutFrame = 0;
  const host = () => window.tinybotConsoleHost;
  let reportedCols = 0, reportedRows = 0;
  function updateScrollButton() {
    const buffer = terminal.buffer.active;
    latest.hidden = buffer.viewportY >= buffer.baseY;
  }
  terminal.onScroll(updateScrollButton);
  latest.addEventListener('pointerdown', event => event.preventDefault());
  latest.addEventListener('click', () => terminal.scrollToBottom());
  function scheduleFit() {
    if (layoutFrame) return;
    layoutFrame = requestAnimationFrame(() => {
      layoutFrame = 0;
      if (surface.clientWidth > 0 && surface.clientHeight > 0) {
        fit.fit();
        if (terminal.cols !== reportedCols || terminal.rows !== reportedRows) {
          reportedCols = terminal.cols;
          reportedRows = terminal.rows;
          host().consoleSize(reportedCols, reportedRows);
        }
        updateScrollButton();
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
    configure(label, language, latestLabel) {
      document.documentElement.lang = language;
      surface.setAttribute('aria-label', label);
      terminal.textarea?.setAttribute('aria-label', label);
      latest.setAttribute('aria-label', latestLabel);
      latest.title = latestLabel;
      scheduleFit();
    },
    setAppearance(fontSize, cursorStyle) {
      terminal.options.fontSize = fontSize;
      terminal.options.cursorStyle = cursorStyle;
      terminal.options.cursorInactiveStyle = cursorStyle;
      scheduleFit();
    },
    write(encoded, receipt, history) {
      const raw = atob(encoded);
      const bytes = Uint8Array.from(raw, (char) => char.charCodeAt(0));
      writingHistory = history;
      terminal.write(bytes, () => {
        writingHistory = false;
        host().consoleWritten(receipt);
      });
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
      const keys = { esc: '\x1b', tab: '\t', interrupt: '\x03', lineStart: '\x01',
        lineEnd: '\x05', clear: '\x0c', pipe: '|', slash: '/' };
      const arrows = { up: 'A', down: 'B', right: 'C', left: 'D' };
      const prefix = terminal.modes.applicationCursorKeysMode ? '\x1bO' : '\x1b[';
      const data = keys[name] ?? (arrows[name] ? prefix + arrows[name] : '');
      if (data && !terminal.options.disableStdin) {
        host().consoleInput(data);
        terminal.focus();
      }
    },
    copy() {
      const nativeSelection = window.getSelection();
      const selected = terminal.getSelection() || (surface.contains(nativeSelection?.anchorNode)
        ? nativeSelection.toString() : '');
      if (selected) { host().consoleCopy(selected, false); return; }
      const buffer = terminal.buffer.active;
      const end = Math.min(buffer.length, buffer.viewportY + terminal.rows);
      const lines = [];
      for (let row = buffer.viewportY; row < end; row++) {
        const line = buffer.getLine(row);
        const wraps = row + 1 < end && buffer.getLine(row + 1)?.isWrapped;
        const text = line.translateToString(!wraps);
        if (line.isWrapped && lines.length) lines[lines.length - 1] += text;
        else lines.push(text);
      }
      while (lines.length && !lines[lines.length - 1]) lines.pop();
      host().consoleCopy(lines.join('\n'), true);
    },
    paste(text) {
      if (terminal.options.disableStdin) return;
      terminal.paste(text);
      terminal.focus();
    },
  };
})();
