import { build } from 'esbuild';
import { copyFileSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
await build({entryPoints:['web/reader.js'],bundle:true,format:'iife',globalName:'FolioModule',outfile:'Sources/MarkdownReader/Resources/reader.js',minify:true,legalComments:'eof'});
copyFileSync('Fixtures/Welcome.md','Sources/MarkdownReader/Resources/Welcome.md');
let mathCSS=readFileSync('node_modules/katex/dist/katex.min.css','utf8');
mathCSS=mathCSS.replace(/url\((?:["']?)(fonts\/[^)'" ]+)["']?\)/g,(_,font)=>{
 const ext=font.split('.').pop(),type=ext==='ttf'?'ttf':ext;
 return `url(data:font/${type};base64,${readFileSync('node_modules/katex/dist/'+font).toString('base64')})`;
});
writeFileSync('Sources/MarkdownReader/Resources/math.css',mathCSS);
let notices='Third-party notices\n\n';
function collect(dir){for(const entry of readdirSync(dir,{withFileTypes:true})){
 if(!entry.isDirectory()||entry.name.startsWith('.'))continue;
 const path=dir+'/'+entry.name;if(entry.name.startsWith('@')){collect(path);continue;}
 const pkg=path+'/package.json';if(!existsSync(pkg))continue;
 const info=JSON.parse(readFileSync(pkg,'utf8'));notices+=`${info.name} ${info.version} (${info.license||'see license'})\n`;
 for(const file of readdirSync(path).filter(f=>/^(licen[sc]e|copying|notice)(\.|$)/i.test(f))){try{notices+=readFileSync(path+'/'+file,'utf8')+'\n';}catch{}}
 if(existsSync(path+'/node_modules'))collect(path+'/node_modules');
}}
collect('node_modules');
writeFileSync('Sources/MarkdownReader/Resources/THIRD_PARTY.txt',notices);
