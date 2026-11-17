const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const cache = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule');

function debugArtifact(relative) {
  const source = path.join(root, 'entry/src/main/ets', relative + '.ets');
  const emitted = path.join(cache, 'debug/entry/src/main/ets', relative + '.ts');
  const manifest = path.join(cache, 'debug/filesInfo.txt');
  const checked = path.join(cache, '.ts_checker_cache');
  const rebuild = 'Rebuild Debug before testing ' + relative;
  assert.ok([emitted, manifest, checked].every(file => fs.existsSync(file)), rebuild + ': compiler output is missing');

  // DevEco can reuse byte-identical emitted files and keep their old timestamps.
  const inputTime = fs.statSync(source).mtimeMs;
  const compilerInput = JSON.parse(fs.readFileSync(checked, 'utf8')).fileList[source];
  assert.equal(compilerInput?.mtimeMs, inputTime, rebuild + ': compiler input changed');
  assert.ok(fs.statSync(manifest).mtimeMs >= inputTime, rebuild + ': Debug compilation predates the input');
  const files = fs.readFileSync(manifest, 'utf8').split(/\r?\n/);
  assert.ok(files.some(line => path.normalize(line.split(';', 1)[0]) === emitted),
    rebuild + ': expected output is absent from the Debug compiler manifest');
  return emitted;
}

module.exports = { debugArtifact };
