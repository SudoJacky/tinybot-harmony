// Shared native-test adapter: use the production collector and sanitizer rather than logging stubs.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  } }).outputText, { exports, require: id => load(path.resolve(path.dirname(file), id)) });
  return exports;
}
module.exports = load(path.resolve(__dirname, '../entry/src/main/ets/model/Diagnostics'));
