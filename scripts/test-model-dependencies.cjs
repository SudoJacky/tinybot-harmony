// Guard value dependencies after type erasure; interfaces may refer to each other freely.
const fs = require('node:fs'), path = require('node:path');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
function filesIn(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? filesIn(file) : entry.name.endsWith('.ets') ? [file] : [];
  });
}
const files = filesIn(root), graph = new Map(files.map(file => [file, []]));
for (const file of files) {
  const emitted = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText;
  const tree = ts.createSourceFile(file + '.js', emitted, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
  function imports(node) {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'require' &&
      node.arguments.length === 1 && ts.isStringLiteral(node.arguments[0])) {
      const id = node.arguments[0].text;
      if (id.startsWith('.')) {
        const dependency = path.resolve(path.dirname(file), id.endsWith('.ets') ? id : id + '.ets');
        if (!graph.has(dependency)) throw Error('Unresolved local dependency: ' + file + ' -> ' + id);
        graph.get(file).push(dependency);
      }
    }
    ts.forEachChild(node, imports);
  }
  imports(tree);
}
const active = new Set(), complete = new Set(), stack = [];
function visit(file) {
  if (active.has(file)) {
    const cycle = stack.slice(stack.indexOf(file)).concat(file).map(item => path.relative(root, item));
    throw Error('Runtime dependency cycle:\n' + cycle.join('\n -> '));
  }
  if (complete.has(file)) return;
  active.add(file); stack.push(file);
  for (const dependency of graph.get(file)) visit(dependency);
  stack.pop(); active.delete(file); complete.add(file);
}
for (const file of files) visit(file);
console.log('PASS ' + files.length + ' ArkTS modules have no runtime dependency cycles; type-only references are excluded');
