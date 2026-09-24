import test from 'node:test';
import assert from 'node:assert/strict';
import {parse} from '../web/parser.js';
import {replacePassage,serialize,serializeDocument} from '../web/editing.js';
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
