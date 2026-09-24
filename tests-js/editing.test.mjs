import test from 'node:test';
import assert from 'node:assert/strict';
import {parse} from '../web/parser.js';
import {replacePassage,serialize,serializeDocument} from '../web/editing.js';
import {safeLinkDestination,safeImagePath,parseCodeSource,formatCodeSource,parseTableSource,formatTableSource,parseImageSource,formatImageSource} from '../web/complex-source.js';
test('editing preserves front matter, CRLF, code and footnotes outside changed passage',()=>{
 const source='---\r\ntitle: Private\r\n---\r\n\r\n# Heading\r\n\r\nOrdinary prose.\r\n\r\n```js\r\n  x();  \r\n```\r\n\r\nRef[^a]\r\n\r\n[^a]: original\r\n';
 const result=parse(source,'',true),block=result.blocks.find(b=>source.slice(b.start,b.end).startsWith('Ordinary'));
 assert.ok(block);const changed=replacePassage(source,result.blocks,block.id,'Updated **prose**.');
 assert.equal(changed.source,source.replace('Ordinary prose.','Updated **prose**.'));
});
test('successive edits adjust later source offsets including emoji',()=>{
 const source='# Heading\n\nFirst.\n\nLast.\n';let {blocks}=parse(source,'',true);
 let result=replacePassage(source,blocks,blocks[1].id,'First 🦊 extended.');
 result=replacePassage(result.source,result.blocks,blocks[2].id,'Final.');
 assert.equal(result.source,'# Heading\n\nFirst 🦊 extended.\n\nFinal.\n');
});
test('special syntax and hidden comments are not converted by the rich editor',()=>{
 const source='Text %% private %% here.\n\nWiki [[note]].\n\nMath $x$.\n\nRef [name][id].\n\n[id]: https://example.com\n\nPlain.\n';
 const result=parse(source,'',true);assert.equal(result.blocks.length,1);assert.equal(source.slice(result.blocks[0].start,result.blocks[0].end),'Plain.\n');
 assert.equal(parse(source).blocks.length,0);
});
test('ordinary nested lists and quotes are mapped as whole editable passages',()=>{
 const source='- First\n  - Nested\n- Last\n\n> Quote\n';
 const result=parse(source,'',true);assert.equal(result.blocks.length,2);
 assert.equal(source.slice(result.blocks[0].start,result.blocks[0].end),'- First\n  - Nested\n- Last\n\n');
});
test('serializer escapes literal syntax and retains semantic emphasis',()=>{
 const text=s=>({nodeType:3,nodeValue:s});const el=(tag,...children)=>({nodeType:1,tagName:tag,childNodes:children});
 assert.equal(serialize(el('P',text('Literal * star '),el('STRONG',text('bold')))),'Literal \\* star **bold**\n\n');
});

const textNode=value=>({nodeType:3,nodeValue:value,textContent:value});
const element=(tag,...children)=>({nodeType:1,tagName:tag,childNodes:children,get textContent(){return children.map(c=>c.textContent).join('');}});
test('continuous editor keeps exact source for untouched passages and protected content',()=>{
 const paragraph=element('P',textNode('Untouched * literal.'));
 const code=element('DIV',textNode('Rendered code'));
 const records=new WeakMap([[paragraph,{raw:'Untouched \\* literal.\r\n\r\n',baseline:serialize(paragraph)}],[code,{raw:'```js\r\n  const x = 1;  \r\n```\r\n',locked:true}]]);
 const expected=records.get(paragraph).raw+records.get(code).raw;
 assert.equal(serializeDocument([paragraph,code],records,null,'\r\n'),expected);
});
test('a replacement spanning paragraphs serializes once and preserves the following code',()=>{
 const merged=element('P',textNode('One replacement across two paragraphs.'));
 const code=element('DIV',textNode('Code'));
 const records=new WeakMap([[code,{raw:'```text\nunchanged  \n```',locked:true}]]);
 assert.equal(serializeDocument([merged,code],records,null),'One replacement across two paragraphs.\n\n```text\nunchanged  \n```');
});
test('appending after a document without a final newline creates a separate paragraph',()=>{
 const first=element('P',textNode('First.')),tail=element('P',textNode('Next.'));
 const records=new WeakMap([[first,{raw:'First.',baseline:serialize(first)}]]);
 assert.equal(serializeDocument([first,tail],records,tail),'First.\n\nNext.\n\n');
});

test('line breaks survive Markdown rendering without becoming paragraphs',()=>{
 const paragraph=element('P',textNode('First line'),element('BR'),textNode('Second line'));
 const markdown=serialize(paragraph);
 assert.equal(markdown,'First line  \nSecond line\n\n');
 const rendered=parse(markdown).html;
 assert.match(rendered,/<br\s*\/?>/);
 assert.equal((rendered.match(/<p(?:\s|>)/g)||[]).length,1);
});

test('complex block mapping is exact and leaves unsupported variants in Source',()=>{
 const source='---\r\ntitle: Kept\r\n---\r\n\r\nText.\r\n\r\n```js\r\nconst x = 1;  \r\n```\r\n\r\n| A | B |\r\n|---|---|\r\n| 1 | 2 |\r\n\r\n![Local](image.png)\r\n\r\n```mermaid\r\ngraph LR\r\n A --> B\r\n```\r\n';
 const result=parse(source,'folio-asset://test/',true);
 assert.deepEqual(result.complexBlocks.map(block=>block.kind),['code','table','image']);
 for(const block of result.complexBlocks)assert.equal(source.slice(block.start,block.end).includes('\r\n'),true);
 assert.equal((result.html.match(/data-complex=/g)||[]).length,3);
 assert.ok(!result.html.includes('<p><figure'));
 assert.ok(!result.complexBlocks.some(block=>source.slice(block.start,block.end).includes('mermaid')));
});

test('code edit keeps marker style and surrounding source while escaping rendered HTML',()=>{
 const source='Before.\r\n\r\n~~~~html\r\nold\r\n~~~~\r\n\r\nAfter.\r\n';
 const {complexBlocks}=parse(source,'',true),block=complexBlocks[0],current=parseCodeSource(source.slice(block.start,block.end));
 assert.equal(current.text,'old');
 const replacement=formatCodeSource(current,'html','<script>alert(1)</script>\n~~~');
 const updated=replacePassage(source,complexBlocks,block.id,replacement).source;
 assert.ok(updated.startsWith('Before.\r\n\r\n~~~~html\r\n'));
 assert.ok(updated.endsWith('\r\nAfter.\r\n'));
 assert.match(updated,/~~~~html\r\n<script>alert\(1\)<\/script>\r\n~~~\r\n~~~~/);
 const rendered=parse(updated).html;
 assert.ok(!rendered.includes('<script>'));assert.ok(rendered.includes('&lt;')&&rendered.includes('&gt;'));
});

test('code text containing a fence cannot spill into the following document',()=>{
 const original=parseCodeSource('```js\nold\n```\n');
 const updated=formatCodeSource(original,'js','```\n# still code');
 const source=updated+'\nAfter.\n',rendered=parse(source);
 assert.ok(updated.startsWith('````js\n'));
 assert.equal(rendered.codeBlocks[0],'```\n# still code\n');
 assert.ok(rendered.html.includes('After.'));
});

test('table edits preserve other source, alignment and escaped cell text',()=>{
 const source='<!-- literal -->\n\n| Name | Count |\n|:---|---:|\n| A | 1 |\n\nFollowing.\n';
 const {complexBlocks}=parse(source,'',true),block=complexBlocks[0],table=parseTableSource(source.slice(block.start,block.end));
 assert.deepEqual(table.alignment,[{left:true,right:false},{left:false,right:true}]);
 const rows=table.rows.map(row=>[...row]);rows[1][0]='A | B';rows.push(['C','3']);
 const replacement=formatTableSource(table,rows),updated=replacePassage(source,complexBlocks,block.id,replacement).source;
 assert.ok(updated.startsWith('<!-- literal -->\n\n'));
 assert.ok(updated.endsWith('\nFollowing.\n'));
 assert.ok(updated.includes('| A \\| B | 1 |'));
 assert.equal(parse(updated).html.match(/<tr>/g).length,3);
});
test('table cell splitting respects odd and even backslash runs before pipes',()=>{
 const escaped=parseTableSource('| One | Two |\n| --- | --- |\n| A \\| B | C |\n');
 assert.equal(escaped.rows[1][0],'A \\| B');
 const delimiter=parseTableSource('| One | Two |\n| --- | --- |\n| A \\\\| B |\n');
 assert.deepEqual(delimiter.rows[1],['A \\\\','B']);
});
test('table editor rejects oversized shapes and escapes hostile cell content',()=>{
 const tooWide='| '+Array(31).fill('H').join(' | ')+' |\n| '+Array(31).fill('---').join(' | ')+' |\n';
 assert.equal(parseTableSource(tooWide),null);
 const original=parseTableSource('| A |\n|---|\n| x |\n');
 const updated=formatTableSource(original,[['A'],['<img src=x onerror=alert(1)>']]);
 const rendered=parse(updated).html;
 assert.ok(!rendered.includes('<img'));
 assert.ok(rendered.includes('&lt;img'));
});

test('image editor accepts only local paths and renderer never emits a remote src',()=>{
 const original=parseImageSource('![A](photo.png)\n');
 assert.equal(original.path,'photo.png');
 const updated=formatImageSource(original,'New <alt>','folder/new image.png');
 assert.equal(updated,'![New <alt>](<folder/new%20image.png>)\n');
 const rendered=parse(updated,'folio-asset://test/').html;
 assert.ok(rendered.includes('&lt;alt&gt;'));
 assert.ok(rendered.includes('src="folio-asset://test/folder%2Fnew%20image.png"'));
 for(const unsafe of ['https://example.com/a.png','https%3A%2F%2Fexample.com%2Fa.png','file:///tmp/a.png','/absolute.png','%2Fabsolute.png','../outside.png','%2E%2E/outside.png','javascript:alert(1)','evil" onerror="x','not-an-image.svg'])assert.equal(safeImagePath(unsafe),null);
});

test('malformed complex source and unsafe links are rejected without replacement',()=>{
 assert.equal(parseCodeSource('```js\nno closing fence'),null);
 assert.equal(parseTableSource('| A | B |\n| --- | nope |\n| x | y |\n'),null);
 assert.equal(parseImageSource('![alt][reference]\n'),null);
 assert.equal(formatCodeSource(parseCodeSource('```js\nx\n```\n'),'bad language','x'),null);
 for(const unsafe of ['javascript:alert(1)','data:text/html,x','\njavascript:alert(1)','//example.com','foo bar','foo<bar>','https://','mailto:','relative"title'])assert.equal(safeLinkDestination(unsafe),null);
 assert.equal(safeLinkDestination('notes/page.md'),'notes/page.md');
 const malicious={nodeType:1,tagName:'A',getAttribute:name=>name==='href'?'javascript:alert(1)':null,childNodes:[{nodeType:3,nodeValue:'Safe text'}]};
 assert.equal(serialize(malicious),'Safe text');
});

test('editing a link rewrites its passage while adjacent source stays byte-identical',()=>{
 const source='Before  \r\n\r\nSee [old](https://example.com/old).\r\n\r\n```js\r\nkeep();  \r\n```\r\n';
 const link={nodeType:1,tagName:'A',childNodes:[textNode('new')],getAttribute:name=>name==='href'?'https://example.com/new':null,textContent:'new'};
 const paragraph=element('P',textNode('See '),link,textNode('.'));
 const untouched=element('DIV',textNode('Before'));
 const code=element('DIV',textNode('keep'));
 const records=new WeakMap([
  [untouched,{raw:'Before  \r\n\r\n',locked:true}],
  [paragraph,{raw:'See [old](https://example.com/old).\r\n\r\n',baseline:'See [old](<https://example.com/old>).\n\n'}],
  [code,{raw:'```js\r\nkeep();  \r\n```\r\n',locked:true}]
 ]);
 const after=serializeDocument([untouched,paragraph,code],records,null,'\r\n');
 assert.ok(after.startsWith('Before  \r\n\r\nSee [new](<https://example.com/new>).\r\n\r\n'));
 assert.ok(after.endsWith('```js\r\nkeep();  \r\n```\r\n'));
 assert.notEqual(after,source);
});
