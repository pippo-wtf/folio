import test from 'node:test';
import assert from 'node:assert/strict';
import {layoutCSS} from '../web/layout.js';
test('settings cannot inject external CSS or markup',()=>{
 const css=layoutCSS({bodyFont:'x; background:url(https://evil)',accent:'</style><script>',paragraphGap:Infinity});
 assert.ok(!css.includes('evil'));assert.ok(!css.includes('<script>'));assert.ok(!css.includes('Infinity'));
 assert.ok(css.includes('#2CFF05'));
});
test('layout values affect selected properties and keep readable bounds',()=>{
 const css=layoutCSS({bodySize:36,codeSize:18,columnWidth:999,paragraphGap:2.4,calloutStyle:'plain',headingFont:'Georgia'});
 assert.ok(css.includes('max-width:calc(90ch +'));assert.ok(css.includes('margin-bottom:2.4em'));
 assert.ok(css.includes('border-left-width:0px'));assert.ok(css.includes('font-size:0.5rem'));
 assert.ok(css.includes('font-family:"Georgia"'));
});

test('font weights respect bundled ranges and bold emphasis',()=>{
 const css=layoutCSS({bodyFont:'Source Serif 4',bodyWeight:500,headingFont:'Oswald',headingWeight:900});
 assert.match(css,/body\{[^}]*font-weight:500/);
 assert.match(css,/h1,h2,h3,h4,h5,h6\{[^}]*font-weight:700/);
 assert.match(css,/strong,b\{font-weight:700/);
});
