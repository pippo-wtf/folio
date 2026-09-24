// Each edit replaces only one parser-mapped passage. Other source bytes stay intact.
export function replacePassage(source, blocks, id, replacement) {
 const block=blocks.find(b=>b.id===id);
 if(!block||block.start<0||block.end<block.start||block.end>source.length)throw new Error('Invalid passage');
 const old=source.slice(block.start,block.end),newline=source.includes('\r\n')?'\r\n':'\n';
 const suffix=old.match(/(?:\r\n|\n|\r)+$/)?.[0]||'';
 const value=replacement.replace(/\r\n|\r/g,'\n').replace(/\n+$/,'').replace(/\n/g,newline)+suffix;
 const delta=value.length-(block.end-block.start);
 return {source:source.slice(0,block.start)+value+source.slice(block.end),blocks:blocks.map(b=>b.id===id?{...b,end:b.end+delta}:b.start>=block.end?{...b,start:b.start+delta,end:b.end+delta}:b)};
}
const escapeText=s=>s.replace(/\\/g,'\\\\').replace(/([`*_{}\[\]<>#!|~^=])/g,'\\$1').replace(/(^|\n)(\s*)([-+]|\d+[.)])(?=\s)/g,'$1$2\\$3');
export function serialize(node){
 if(node.nodeType===3)return escapeText(node.nodeValue.replace(/\u00a0/g,' '));
 if(node.nodeType!==1)return '';
 const inner=()=>[...node.childNodes].map(serialize).join('');
 const tag=node.tagName;
 if(tag==='BR')return '  \n';
 if(tag==='STRONG'||tag==='B')return '**'+inner()+'**';
 if(tag==='EM'||tag==='I')return '*'+inner()+'*';
 if(tag==='S'||tag==='STRIKE'||tag==='DEL')return '~~'+inner()+'~~';
 if(tag==='CODE'){
  const text=node.textContent;const ticks='`'.repeat(Math.max(0,...[...text.matchAll(/`+/g)].map(m=>m[0].length))+1);
  const pad=/^`|`$|^ .* $/.test(text)?' ':'';return ticks+pad+text+pad+ticks;
 }
 if(tag==='A'){
  const href=node.getAttribute('href')||'';
  if(/^(javascript:|data:|vbscript:)/i.test(href))return inner();
  const title=node.getAttribute('title');return '['+inner()+'](<'+href.replace(/[<>\n\r]/g,'')+'>'+(title?' "'+title.replace(/["\\]/g,'\\$&')+'"':'')+')';
 }
 if(/^H[1-6]$/.test(tag))return '#'.repeat(Number(tag[1]))+' '+inner().trim()+'\n\n';
 if(tag==='P'||tag==='DIV')return inner().replace(/\n+$/,'')+'\n\n';
 if(tag==='BLOCKQUOTE')return inner().trim().split('\n').map(line=>'> '+line).join('\n')+'\n\n';
 if(tag==='UL'||tag==='OL')return [...node.children].map((li,i)=>{
  const marker=tag==='OL'?String((Number(node.getAttribute('start'))||1)+i)+'. ':'- ';
  return marker+[...li.childNodes].map(child=>['UL','OL'].includes(child.tagName)?'\n'+serialize(child):serialize(child)).join('').trim().replace(/\n/g,'\n'+' '.repeat(marker.length));
 }).join('\n')+'\n\n';
 return inner(); // Saved-highlight wrappers have no Markdown representation.
}

export function serializeDocument(nodes,original,tail,newline='\n'){
 const read=node=>{
   const record=original.get(node);
   if(record?.locked||node.nodeType===8)return record?.raw||'';
   if(node===tail&&!node.textContent.trim())return '';
   const value=serialize(node);
   if(record&&value===record.baseline)return record.raw;
   return value.replace(/\r\n|\r/g,'\n').replace(/\n/g,newline);
  };
  let next='';
  for(const node of nodes){
   const value=read(node);if(!value)continue;
   if(node===tail&&next&&!next.endsWith(newline+newline))next+=next.endsWith(newline)?newline:newline+newline;
   next+=value;
  }
 return next;
}

let activeCleanup=()=>{};
export function setupEditing(initial,initialBlocks,token,enabled,send){
 activeCleanup();document.getElementById('format-bar')?.remove();
 if(!enabled)return;
 let source=initial,active=null,range=null;
 const root=document.getElementById('document'),original=new WeakMap(),protectedNodes=[];
 const nodes=[...root.childNodes];let pending=[],offset=0;
 const fragment=document.createDocumentFragment();
 function preserve(until){
  const raw=initial.slice(offset,until);
  if(!pending.length&&!raw)return;
  const visible=pending.some(n=>n.nodeType===1||n.textContent.trim());
  if(visible){
   const locked=document.createElement('div');locked.className='source-preserved';locked.contentEditable='false';
   locked.append(...pending);original.set(locked,{raw,locked:true});protectedNodes.push(locked);fragment.append(locked);
  }else{
   const gap=document.createComment('source spacing');original.set(gap,{raw});fragment.append(gap);
  }
  pending=[];
 }
 for(const node of nodes){
  const block=node.nodeType===1&&initialBlocks.find(b=>b.id===node.dataset.edit);
  if(!block){pending.push(node);continue;}
  preserve(block.start);
  const host=document.createElement('div');host.className='edit-passage';host.dataset.edit=block.id;
  node.removeAttribute('data-edit');node.removeAttribute('contenteditable');host.append(node);
  original.set(host,{raw:initial.slice(block.start,block.end),baseline:serialize(host)});
  fragment.append(host);offset=block.end;
 }
 preserve(initial.length);root.replaceChildren(fragment);
 root.contentEditable='true';root.spellcheck=true;root.setAttribute('role','textbox');root.setAttribute('aria-multiline','true');root.setAttribute('aria-label','Document editor');
 const tail=document.createElement('div');tail.className='edit-passage edit-tail';tail.dataset.edit='tail';tail.innerHTML='<p><br></p>';root.append(tail);
 const bar=document.createElement('div');bar.id='format-bar';bar.setAttribute('role','toolbar');bar.setAttribute('aria-label','Text formatting');
 bar.innerHTML='<div class="format-actions"><button data-block="p">Body</button><button data-block="h1">Heading 1</button><button data-block="h2">Heading 2</button><button data-command="insertUnorderedList">List</button><button data-command="insertOrderedList">Numbered</button><button data-block="blockquote">Quote</button><button data-command="bold"><b>Bold</b></button><button data-command="italic"><i>Italic</i></button><button data-command="strikeThrough"><s>Strike</s></button><button data-link>Link</button></div><span id="word-count"></span>';
 document.body.append(bar);
 const count=()=>{bar.querySelector('#word-count').textContent=(root.innerText.trim().match(/\S+/g)||[]).length.toLocaleString()+' words';};count();
 function commit(){
  if(protectedNodes.some(node=>node.parentNode!==root)){
   send({type:'editingRejected',token});return;
  }
  const newline=initial.includes('\r\n')?'\r\n':'\n';
  const next=serializeDocument(root.childNodes,original,tail,newline);
  if(next!==source){const before=source;source=next;send({type:'editDocument',token,before,text:source,passage:'document'});}
  count();
 }
 const select=()=>{
  const selection=getSelection();if(!selection?.rangeCount)return;
  const r=selection.getRangeAt(0);
  if(root.contains(r.startContainer)&&root.contains(r.endContainer)){active=root;range=r.cloneRange();}
 };
 const blocked=r=>protectedNodes.some(node=>r.intersectsNode(node));
 const notice=()=>send({type:'copyNotice',text:'This selection includes a complex block. Use Source to change that block; surrounding text is editable here.'});
 const input=()=>commit();
 const paste=e=>{
  e.preventDefault();const selection=getSelection();if(selection?.rangeCount&&blocked(selection.getRangeAt(0))){notice();return;}
  document.execCommand('insertText',false,e.clipboardData.getData('text/plain'));commit();
 };
 const keydown=e=>{
  if(e.metaKey&&e.key.toLowerCase()==='z'){e.preventDefault();send({type:e.shiftKey?'redoEdit':'undoEdit'});return;}
  if(e.key==='Enter'&&e.shiftKey&&!e.metaKey&&!e.ctrlKey&&!e.altKey&&!e.isComposing){
   e.preventDefault();
   const selection=getSelection();if(!selection?.rangeCount)return;
   if(blocked(selection.getRangeAt(0))){notice();return;}
   document.execCommand('insertLineBreak',false,null);commit();select();
  }
 };
 const drop=e=>e.preventDefault();
 const beforeinput=e=>{
  if(!e.inputType.startsWith('delete')&&!e.inputType.startsWith('insert'))return;
  const selection=getSelection();if(!selection?.rangeCount)return;
  if(blocked(selection.getRangeAt(0))){e.preventDefault();notice();}
 };
 bar.addEventListener('mousedown',e=>{if(e.target.closest('button'))e.preventDefault();});
 bar.addEventListener('click',e=>{
  const button=e.target.closest('button');if(!button)return;
  if(!active){active=root;active.focus();const r=document.createRange();r.selectNodeContents(tail);r.collapse(false);range=r;}
  if(range&&blocked(range)){notice();return;}
  active.focus();if(range){getSelection().removeAllRanges();getSelection().addRange(range);}
  if(button.hasAttribute('data-link')){
   // Inline field keeps WebKit modal dialogs out of the editing flow.
   let field=bar.querySelector('input');if(field){field.focus();return;}
   field=document.createElement('input');field.type='url';field.placeholder='https://… · Enter to add';field.setAttribute('aria-label','Link address');bar.append(field);field.focus();
   field.addEventListener('keydown',event=>{if(event.key==='Escape'){field.remove();active.focus();}if(event.key==='Enter'){
    const url=field.value.trim();if(!/^(https?:|mailto:|#)/i.test(url))return;
    active.focus();getSelection().removeAllRanges();getSelection().addRange(range);document.execCommand('createLink',false,url);commit(active);field.remove();
   }});return;
  }
  document.execCommand(button.dataset.block?'formatBlock':button.dataset.command,false,button.dataset.block||null);commit(active);select();
 });
 root.addEventListener('keydown',keydown);root.addEventListener('input',input);root.addEventListener('paste',paste);root.addEventListener('drop',drop);root.addEventListener('beforeinput',beforeinput);document.addEventListener('selectionchange',select);
 activeCleanup=()=>{root.removeAttribute('contenteditable');root.removeAttribute('role');root.removeAttribute('aria-multiline');root.removeEventListener('keydown',keydown);root.removeEventListener('input',input);root.removeEventListener('paste',paste);root.removeEventListener('drop',drop);root.removeEventListener('beforeinput',beforeinput);document.removeEventListener('selectionchange',select);};
}
