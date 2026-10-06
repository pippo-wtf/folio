import test from 'node:test';
import assert from 'node:assert/strict';
import {setupEditing} from '../web/editing.js';
// Small DOM fixture exercises the real controller and serializer without a browser dependency.
class Node extends EventTarget {
 constructor(tag='',text='',type=1){super();this.nodeType=type;this.tagName=tag.toUpperCase();this.nodeValue=text;this.childNodes=[];this.dataset={};this.style={setProperty(){}};this.attributes={};this.className='';}
 get textContent(){return this.nodeType===3||this.nodeType===8?this.nodeValue:this.childNodes.map(n=>n.textContent).join('');}
 set textContent(v){this.replaceChildren(new Node('',v,3));}
 append(...nodes){for(const n of nodes){n.remove();n.parentNode=this;this.childNodes.push(n);}}
 remove(){if(this.parentNode){this.parentNode.childNodes=this.parentNode.childNodes.filter(n=>n!==this);this.parentNode=null;}}
 replaceChildren(...nodes){this.childNodes.forEach(n=>n.parentNode=null);this.childNodes=[];for(const n of nodes)this.append(...(n.nodeType===11?[...n.childNodes]:[n]));}
 removeAttribute(k){delete this.attributes[k];}
 setAttribute(k,v){this.attributes[k]=v;}
 getAttribute(k){return this.attributes[k]??null;}
 get isContentEditable(){return this.contentEditable==='true';}
 querySelectorAll(){return [];}
 querySelector(s){if(s==='#word-count')return this.counter??=new Node('span');if(s==='input')return this.linkField??null;return null;}
 set innerHTML(v){if(v==='<p><br></p>')this.append(new Node('p'));}
}
function fixture(source='Original.\r\n',enabled=true,protectedBlock=false){
 const root=new Node('main'),body=new Node('body'),p=new Node('p');p.dataset.edit='a';p.textContent='Original.';root.append(p);
 if(protectedBlock)root.append(new Node('pre','',1));
 globalThis.document={getElementById:id=>id==='document'?root:null,createElement:tag=>new Node(tag),createComment:t=>new Node('',t,8),createDocumentFragment:()=>new Node('','',11),createTreeWalker:()=>({nextNode:()=>null}),fonts:{ready:Promise.resolve()},body,addEventListener(){},removeEventListener(){}};
 globalThis.NodeFilter={SHOW_TEXT:4};globalThis.ResizeObserver=class{observe(){}disconnect(){}};globalThis.requestAnimationFrame=()=>{};
 const messages=[];const controller=setupEditing(source,[{id:'a',start:0,end:protectedBlock?source.indexOf('```'):source.length}],[],'','token',enabled,m=>messages.push(m));
 return {root,p,controller,messages};
}
test('snapshot flushes pending DOM and delivers edit before exact snapshot',()=>{
 const f=fixture();f.p.textContent='Updated.';f.controller.requestContent('one');
 assert.deepEqual(f.messages.map(m=>m.type),['editDocument','contentReady']);
 assert.equal(f.messages[1].text,'Updated.\r\n\r\n');assert.equal(f.messages[1].requestID,'one');f.controller.cleanup();
});
test('read mode acknowledges untouched source including authored metadata',()=>{
 const source='---\r\ntitle: Mine\r\n---\r\n<!-- mine -->\r\n- [x] done\r\n';const f=fixture(source,false);
 f.controller.requestContent('read');assert.deepEqual(f.messages,[{type:'contentReady',requestID:'read',token:'token',text:source}]);f.controller.cleanup();
});
test('composition waits through final input before acknowledging',async()=>{
 const f=fixture();f.root.dispatchEvent(new Event('compositionstart'));f.controller.requestContent('ime');
 assert.equal(f.messages.length,0);f.root.dispatchEvent(new Event('compositionend'));f.p.textContent='Final.';f.root.dispatchEvent(new Event('input'));
 await new Promise(r=>setTimeout(r,5));assert.equal(f.messages.at(-1).text,'Final.\r\n\r\n');assert.equal(f.messages.at(-1).type,'contentReady');f.controller.cleanup();
});
test('protected-node rejection cannot acknowledge success',()=>{
 const f=fixture('Original.\n\n```js\nx\n```\n',true,true);f.root.childNodes.find(n=>n.className==='source-preserved').remove();f.controller.requestContent('reject');
 assert.ok(f.messages.some(m=>m.type==='editingRejected'));assert.ok(!f.messages.some(m=>m.type==='contentReady'));f.controller.cleanup();
});
test('open link draft rejects copying and cleanup cancels deferred requests',async()=>{
 const f=fixture();document.body.childNodes.find(n=>n.id==='format-bar').linkField=new Node('input');f.controller.requestContent('modal');
 assert.equal(f.messages.at(-1).type,'contentFailed');assert.equal(f.messages.at(-1).text,'Apply or cancel the open edit before copying.');
 f.root.dispatchEvent(new Event('compositionstart'));f.controller.requestContent('cancel');f.controller.cleanup();f.root.dispatchEvent(new Event('compositionend'));
 await new Promise(r=>setTimeout(r,5));assert.ok(!f.messages.some(m=>m.type==='contentReady'));
});
