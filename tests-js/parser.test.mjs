import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {parse} from '../web/parser.js';
test('headings are unique including collisions with generated suffixes',()=>{
 const result=parse('# Same\n# Same\n# Same-1\n# 日本語');
 assert.equal(new Set(result.headings.map(x=>x.id)).size,4);
 assert.equal(result.headings[3].title,'日本語');
});
test('raw HTML cannot become executable markup',()=>{
 const result=parse(readFileSync('Fixtures/Hostile.md','utf8'));
 assert.ok(!result.html.includes('<script>'));
 assert.ok(!result.html.includes('<img src="https:'));
 assert.ok(result.html.includes('&lt;script&gt;'));
 assert.ok(!result.html.includes('href="javascript:'));
});
test('tables, repeated footnotes and disabled tasks render',()=>{
 const result=parse('| A | B |\n|---|---|\n| 1 | 2 |\n\nText[^a] and again[^a].\n\n[^a]: Evidence\n\n- [x] Done');
 assert.match(result.html,/<table>/);assert.match(result.html,/footnote-ref/);
 assert.match(result.html,/disabled/); assert.match(result.html,/checked/);
});
test('code copy payload preserves tabs spaces and content',()=>{
 const code='\tlet a = 1;  \n<script>literal</script>\n';
 const result=parse('```html\n'+code+'```');
 assert.equal(result.codeBlocks[0],code);
 assert.ok(!result.html.includes('<script>literal'));
});
test('remote images are rewritten to native denied-by-default scheme',()=>{
 const result=parse('![remote](https://example.com/x.png)','folio-asset://test/');
 assert.equal(result.images[0].reference,'https://example.com/x.png');
 assert.ok(!result.html.includes('src="https:'));
 assert.match(result.html,/src="folio-asset:/);
});
test('equations render and Mermaid retains exact source alongside preview',()=>{
 const result=parse('```mermaid\ngraph LR\n A --> B\n```\n\n$$x^2$$');
 assert.match(result.html,/data-diagram="0"/);assert.match(result.html,/class="katex/);
 assert.equal(result.diagrams[0],'graph LR\n A --> B\n');assert.equal(result.codeBlocks[0],result.diagrams[0]);
});
test('empty malformed and long fixtures render without dropping final section',()=>{
 assert.equal(parse('').html,'');
 assert.ok(parse(readFileSync('Fixtures/Malformed.md','utf8')).html.includes('unclosed fence'));
 const result=parse(readFileSync('Fixtures/Large.md','utf8'));assert.equal(result.headings.length,2001);
 assert.ok(result.html.includes('Section 1999'));
});

 test('frontmatter stays available without becoming an outline heading',()=>{
 const r=parse('---\ntitle: Notes\nunknown: <script>\n---\n# Reading');
 assert.equal(r.headings.length,1);assert.match(r.html,/Document properties/);assert.match(r.html,/&lt;script&gt;/);
 });
 test('Obsidian callouts preserve body and nested blockquotes safely',()=>{
 const r=parse('> [!warning]- <img onerror=x>\n> Keep **this**.\n>\n> > Quoted text\n\n> Normal quote');
 assert.match(r.html,/<details class="callout" data-kind="warning">/);
 assert.match(r.html,/&lt;img onerror=x&gt;/);assert.match(r.html,/<strong>this<\/strong>/);
 assert.match(r.html,/<blockquote>/);assert.match(r.html,/Normal quote/);
 });
 test('expanded callout and source folding preserve exact copy text',()=>{
 const r=parse('> [!tip]+ Useful\n> Read this.\n\n```js\nconst x = 1;\n```');
 assert.match(r.html,/data-kind="tip" open/);assert.match(r.html,/source-details/);
 assert.equal(r.codeBlocks[0],'const x = 1;\n');
 });

test('code blocks expose one disclosure and independent copy control',()=>{
 const r=parse('```js\nconst x = "<unsafe>";\n```');
 assert.equal((r.html.match(/<summary>/g)||[]).length,1);
 assert.match(r.html,/<button class="code-copy"[^>]*data-copy="0"/);
 assert.match(r.html,/<pre tabindex="0" aria-label="Code">/);
 assert.ok(!r.html.includes('code-label'));
 assert.equal(r.codeBlocks[0],'const x = "<unsafe>";\n');
});


test('writing extensions render without changing code literals',()=>{
 const r=parse('==marked== H~2~O x^2^\n\nTerm\n: Meaning\n\nhttps://example.com\n\n`==raw== %%keep%%`');
 for(const fragment of ['<mark>marked</mark>','<sub>2</sub>','<sup>2</sup>','<dl>','href="https://example.com"','==raw== %%keep%%'])assert.ok(r.html.includes(fragment),fragment);
});
test('comments are hidden in prose and preserved in fenced source',()=>{
 const r=parse('%%\nhidden block\n%%\n\nVisible %%secret%% words\n\n```text\n%%literal%%\n```');
 assert.ok(!r.html.includes('hidden block'));assert.ok(!r.html.includes('secret'));
 assert.match(r.html,/Visible  words/);assert.equal(r.codeBlocks[0],'%%literal%%\n');
});
test('wiki references and image embeds are escaped and routed locally',()=>{
 const r=parse('[[Note|Read this]] [[#Section]] ![[photo.png]] ![[Other note]] [[javascript:bad|<img>]]');
 assert.match(r.html,/data-note="Note">Read this/);assert.match(r.html,/href="#Section"/);
 assert.equal(r.images[0].reference,'photo.png');assert.match(r.html,/open separately/);
 assert.ok(!r.html.includes('href="javascript:'));assert.match(r.html,/&lt;img&gt;/);
});
test('code colouring preserves exact copy and unsupported languages remain readable',()=>{
 const r=parse('```js\nconst text = "<tag>";\n```\n\n```unknown-language\n<literal>\n```');
 assert.match(r.html,/hljs-keyword/);assert.equal(r.codeBlocks[0],'const text = "<tag>";\n');
 assert.match(r.html,/&lt;literal&gt;/);assert.ok(!r.html.includes('<tag>'));
});
test('math errors and resource commands cannot introduce executable markup',()=>{
 const r=parse('```math\n\\notARealCommand{<script>}\n```\n\n$\\includegraphics{https://example.com/x.png}$');
 assert.match(r.html,/Equation could not be rendered/);assert.ok(!r.html.includes('<script>'));
 assert.ok(!r.html.includes('<img'));assert.equal(r.images.length,0);
});
test('full formatting fixture renders all headings and keeps end sentinel',()=>{
 const r=parse(readFileSync('Fixtures/Formatting.md','utf8'));
 assert.ok(r.headings.length>=15);assert.equal(r.diagrams.length,3);
 assert.match(r.html,/End of formatting check/);assert.match(r.html,/katex/);
});

test('fenced equations keep display layout after an inline equation',()=>{
 const r=parse('$x$\n\n```math\nx^2\n```');
 assert.match(r.html,/<div class="math-preview"><span class="katex-display">/);
});
