// Render the HarmonyOS vector source; keep desktop artwork independent.
const fs = require('node:fs');
const path = require('node:path');
const { Resvg } = require(process.argv[2] ? path.resolve(process.argv[2]) : '@resvg/resvg-js');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'assets/app-icon.svg'), 'utf8');
const background = source.match(/<rect id="background"[^>]*\/>/);
if (!background) throw new Error('Missing background rectangle in assets/app-icon.svg');
const foreground = source.replace(background[0], '');
const backgroundSource = source.replace(/<circle\b[^>]*\/>/g, '');
const media = path.join(root, 'AppScope/resources/base/media');
for (const [name, svg] of [['tinybot_icon', source], ['tinybot_icon_foreground', foreground], ['tinybot_icon_background', backgroundSource]]) {
  fs.writeFileSync(path.join(media, name + '.png'), new Resvg(svg).render().asPng());
}
fs.copyFileSync(path.join(media, 'tinybot_icon.png'), path.join(root, 'entry/src/main/resources/base/media/tinybot_icon.png'));
console.log('Rendered 1024 x 1024 HarmonyOS app icons.');
