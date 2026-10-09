#pragma once

namespace tinybot {
// Loaded only in the async runtime. Helpers share its memory, time and log budgets.
inline constexpr char ORCHESTRATION_HELPERS[] = R"JS(
(() => {
  'use strict';
  const log = console.log;
  function text(value) {
    log(typeof value === 'string' ? value : JSON.stringify(value));
  }
  function as_settled(promises) {
    const ready = [];
    let remaining = 0;
    let wake;
    let closed = false;
    const push = result => {
      remaining--;
      if (closed) return;
      ready.push(result);
      if (wake) { const resolve = wake; wake = undefined; resolve(); }
    };
    let position = 0;
    for (const entry of promises) {
      const index = promises instanceof Map ? entry[0] : position++;
      const promise = promises instanceof Map ? entry[1] : entry;
      remaining++;
      Promise.resolve(promise).then(
        value => push({index, status: 'fulfilled', value}),
        reason => push({index, status: 'rejected', reason})
      );
    }
    return (async function* () {
      try {
        while (remaining || ready.length) {
          if (!ready.length) await new Promise(resolve => { wake = resolve; });
          while (ready.length) yield ready.shift();
        }
      } finally { closed = true; ready.length = 0; }
    })();
  }
  async function stream_settled(promises, emit) {
    if (typeof emit !== 'function') throw new TypeError('stream_settled requires a callback');
    for await (const result of as_settled(promises)) await emit(result);
  }
  Object.assign(globalThis, {text, as_settled, stream_settled});
})();
)JS";
}
