const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const target = path.resolve(__dirname, '../../entry/src/main/resources/rawfile');
const read = (name) => fs.readFileSync(path.join(__dirname, 'node_modules', name));
const notice = (files) => files.map((file) => file + '\n\n' + read(file).toString('utf8').replace(/\r\n/g, '\n').trim()).join('\n\n---\n\n') + '\n';
const script = (name) => read(name).toString('utf8').replace(/\r\n/g, '\n').replace(/\n\/\/# sourceMappingURL=.*\s*$/, '\n');
const outputs = new Map([
  ['interactive-web/chartjs.js', script('chart.js/dist/chart.umd.min.js')],
  ['interactive-web/echarts.js', script('echarts/dist/echarts.min.js')],
  ['interactive-web/inter-latin.woff2', read('@fontsource-variable/inter/files/inter-latin-wght-normal.woff2')],
  ['licenses/chartjs.txt', notice(['chart.js/LICENSE.md', '@kurkle/color/LICENSE.md'])],
  ['licenses/echarts.txt', notice(['echarts/LICENSE', 'echarts/NOTICE', 'echarts/licenses/LICENSE-d3', 'zrender/LICENSE'])],
  ['licenses/inter.txt', read('@fontsource-variable/inter/LICENSE')]
]);

for (const [name, content] of outputs) {
  const file = path.join(target, name);
  if (process.argv.includes('--check')) {
    const actual = fs.readFileSync(file);
    if (typeof content === 'string') assert.equal(actual.toString('utf8').replace(/\r\n/g, '\n'), content, name);
    else assert.deepEqual(actual, content, name);
  } else fs.writeFileSync(file, content);
}
console.log('Verified Chart.js, ECharts and Inter assets.');
