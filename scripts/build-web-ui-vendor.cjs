// Rebuild the vendored runtime with an installed DevEco webpack; downloaded package scripts never run.
// First: npm pack three@0.186.1 --ignore-scripts --pack-destination .hvigor/web-ui-vendor
// Then: node scripts/build-web-ui-vendor.cjs .hvigor/web-ui-vendor/three-0.186.1.tgz
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const archive=path.resolve(process.argv[2]||'.hvigor/web-ui-vendor/three-0.186.1.tgz');
const expected='blFeqb49wRCSGUGj7gtpfnSGHy2lwDk94RhUmS1c/hTby70kvChbWpkJ4Pm1390LqzzvTmzgXKHPEafJwCb8jA==';
if(crypto.createHash('sha512').update(fs.readFileSync(archive)).digest('base64')!==expected)throw Error('Three.js archive integrity mismatch');
const work=path.resolve('.hvigor/web-ui-vendor');fs.mkdirSync(work,{recursive:true});execFileSync('tar',['-xzf',archive,'-C',work]);
const root=work+'/package';const input=work+'/entry.js';
fs.writeFileSync(input,`import * as THREE from ${JSON.stringify(root+'/build/three.module.js')};import {OrbitControls} from ${JSON.stringify(root+'/examples/jsm/controls/OrbitControls.js')};globalThis.THREE=THREE;globalThis.OrbitControls=OrbitControls;`);
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const webpack=require(require.resolve('webpack',{paths:[studio+'/sdk/default/openharmony/ets/build-tools/ets-loader']}));
const output=path.resolve('entry/src/main/resources/rawfile/interactive-web');
webpack({mode:'production',entry:input,resolve:{alias:{three:root+'/build/three.module.js'}},output:{path:output,filename:'three.bundle.js'},optimization:{minimize:true}},(error,stats)=>{
  if(error||stats.hasErrors()){console.error(error||stats.toString({all:false,errors:true}));process.exitCode=1;return;}
  fs.copyFileSync(root+'/LICENSE',output+'/THREE-LICENSE.txt');console.log(stats.toString({all:false,assets:true}));
});
