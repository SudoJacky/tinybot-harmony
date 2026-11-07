// npm pack katex@0.19.0, extract it, then: node scripts/vendor-katex.cjs <package-directory>
// Keep all math resources offline; only WOFF2 fonts are needed by ArkWeb.
const fs = require('node:fs'), path = require('node:path');
const source = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8'));
if (pkg.version !== '0.19.0') throw new Error('Expected KaTeX 0.19.0');
const target = path.resolve(__dirname, '../entry/src/main/resources/rawfile/math');
fs.mkdirSync(target, { recursive: true });
fs.copyFileSync(path.join(source, 'dist/katex.min.js'), path.join(target, 'katex.min.js'));
const css = fs.readFileSync(path.join(source, 'dist/katex.min.css'), 'utf8').replace(/src:[^}]+(?=})/g, declaration => {
  const font = declaration.match(/url\((fonts\/[^)]+\.woff2)\) format\("woff2"\)/);
  if (!font) throw new Error('Unexpected font declaration');
  return 'src:url(data:font/woff2;base64,' + fs.readFileSync(path.join(source, 'dist', font[1])).toString('base64') + ') format("woff2");';
});
fs.writeFileSync(path.join(target, 'katex.min.css'), css);
fs.writeFileSync(path.join(target, 'LICENSE.txt'), 'KaTeX 0.19.0\nhttps://github.com/KaTeX/KaTeX/tree/v0.19.0\n\n' + fs.readFileSync(path.join(source, 'LICENSE'), 'utf8'));
