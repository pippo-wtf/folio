import {anchor,locate,overlaps,unionSelection} from './highlight-anchors.js';
let root,token='',records=[],writable=false,pending=null,busy=false,selecting=false,timer;
const send=message=>window.webkit?.messageHandlers.folio.postMessage(message);
const toolbar=document.createElement('div');toolbar.id='highlight-tools';toolbar.hidden=true;toolbar.setAttribute('role','toolbar');toolbar.setAttribute('aria-label','Text highlighting');
const save=document.createElement('button');save.type='button';save.textContent='Highlight';save.title='Save highlight (⇧⌘H)';
const remove=document.createElement('button');remove.type='button';remove.textContent='Remove highlight';
toolbar.append(save,remove);document.body.append(toolbar);
const status=document.createElement('div');status.id='highlight-status';status.setAttribute('role','status');status.setAttribute('aria-live','polite');status.hidden=true;document.body.append(status);
function announce(text){clearTimeout(timer);status.textContent=text;status.hidden=false;timer=setTimeout(()=>status.hidden=true,6000);}
function nodes(){
 const all=[];if(!root)return all;
 const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.parentElement.closest('button,summary,script,style,.diagram-preview,.math-preview,.katex')?NodeFilter.FILTER_REJECT:NodeFilter.FILTER_ACCEPT});
 let n,start=0;while((n=walker.nextNode())){all.push({node:n,start,end:start+n.length});start+=n.length;}return all;
}
function contents(){return nodes().map(x=>x.node.data).join('');}
function clearMarks(){root.querySelectorAll('mark.folio-highlight').forEach(mark=>mark.replaceWith(...mark.childNodes));root.normalize();}
function paint(){
 clearMarks();const text=contents();let missing=0;
 const ranges=records.map(record=>{const range=locate(text,record);if(!range)missing++;return range?{...range,id:record.id}:null;}).filter(Boolean);
 // Each text node is segmented independently, preserving links, bold, code and paragraphs.
 for(const entry of nodes()){
  const hits=ranges.filter(r=>overlaps(r,entry));if(!hits.length)continue;
  const cuts=[...new Set([entry.start,entry.end,...hits.flatMap(r=>[Math.max(r.start,entry.start),Math.min(r.end,entry.end)])])].sort((a,b)=>a-b);
  const fragment=document.createDocumentFragment();
  for(let i=0;i<cuts.length-1;i++){
   const a=cuts[i],b=cuts[i+1],value=entry.node.data.slice(a-entry.start,b-entry.start);
   const ids=hits.filter(r=>r.start<b&&r.end>a).map(r=>r.id);
   if(ids.length){const mark=document.createElement('mark');mark.className='folio-highlight';mark.dataset.highlightIds=ids.join(' ');mark.title='Saved highlight · click for actions';mark.textContent=value;fragment.append(mark);}
   else fragment.append(document.createTextNode(value));
  }
  entry.node.replaceWith(fragment);
 }
 return missing;
}
function selection(){
 const sel=window.getSelection();if(!sel||sel.isCollapsed||!sel.rangeCount||!root)return null;
 const range=sel.getRangeAt(0);if(!root.contains(range.startContainer)||!root.contains(range.endContainer))return null;
 const entries=nodes();let start=null,end=null;
 for(const e of entries){
  if(!range.intersectsNode(e.node))continue;
  const a=e.node===range.startContainer?range.startOffset:0,b=e.node===range.endContainer?range.endOffset:e.node.length;
  if(b>a){if(start===null)start=e.start+a;end=e.start+b;}
 }
 if(start===null)return null;
 return {start,end,rect:range.getBoundingClientRect()};
}
function show(rect){
 toolbar.hidden=false;
 const width=toolbar.offsetWidth,height=toolbar.offsetHeight;
 toolbar.style.left=Math.max(8,Math.min(window.innerWidth-width-8,rect.left+rect.width/2-width/2))+'px';
 toolbar.style.top=Math.max(8,Math.min(window.innerHeight-height-8,rect.top-height-8))+'px';
}
function newID(){
 const bytes=crypto.getRandomValues(new Uint8Array(16));bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;
 const hex=[...bytes].map(b=>b.toString(16).padStart(2,'0')).join('');
 return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
function update(){
 if(busy||selecting)return;
 const range=selection();if(!range&&pending?.ids&&!toolbar.hidden)return;pending=range;
 if(!range||!writable){toolbar.hidden=true;return;}
 const text=contents();const selected=anchor(text,range.start,range.end,'pending');
 if(!selected){toolbar.hidden=true;return;}
 save.hidden=false;remove.hidden=!records.some(r=>{const found=locate(text,r);return found&&overlaps(found,range);});show(range.rect);
}
function commit(next){
 if(busy||!writable)return;
 if(next.length>1000){announce('This document has reached its limit of 1,000 highlights.');return;}
 if(new TextEncoder().encode(JSON.stringify(next)).length>1900000){announce('Highlight storage is full for this document. Remove a highlight first.');return;}
 busy=true;save.disabled=true;remove.disabled=true;
 send({type:'saveHighlights',token,highlights:next});
}
export function highlightSelection(){
 const range=selection()||pending;
 if(!range){announce('Select some text first, then choose Highlight.');return;}
 if(!writable){announce('Highlights are unavailable until this document is reopened.');return;}
 const text=contents(),merged=unionSelection(range,records.filter(r=>!r.comment).map(r=>locate(text,r)).filter(Boolean));
 const record=anchor(text,merged.start,merged.end,newID());
 if(!record){announce('Select between 1 and 20,000 characters to highlight.');return;}
 const kept=records.filter(r=>{const found=locate(text,r);return r.comment||!found||!overlaps(found,merged);});
 commit([...kept,record]);
}
function removeSelection(){
 if(!pending)return;
 const text=contents(),ids=pending.ids;
 commit(records.filter(r=>{if(ids)return !ids.includes(r.id);const range=locate(text,r);return !range||!overlaps(range,pending);}));
}
for(const button of [save,remove])button.addEventListener('pointerdown',e=>e.preventDefault());
save.addEventListener('click',highlightSelection);remove.addEventListener('click',removeSelection);
document.addEventListener('selectionchange',()=>setTimeout(update,0));
document.addEventListener('pointerdown',event=>{if(root?.contains(event.target)){selecting=true;toolbar.hidden=true;}});
document.addEventListener('pointerup',()=>{selecting=false;setTimeout(update,0);});
document.addEventListener('pointercancel',()=>{selecting=false;toolbar.hidden=true;});
document.addEventListener('click',event=>{
 const mark=event.target.closest('mark.folio-highlight');
 if(mark&&writable&&!busy&&window.getSelection()?.isCollapsed){
  pending={ids:mark.dataset.highlightIds.split(' ')};save.hidden=true;remove.hidden=false;show(mark.getBoundingClientRect());
 }else if(!toolbar.contains(event.target)&&window.getSelection()?.isCollapsed){toolbar.hidden=true;pending=null;}
});
document.addEventListener('keydown',e=>{if(e.key==='Escape'){toolbar.hidden=true;pending=null;}});
window.addEventListener('scroll',()=>toolbar.hidden=true,{passive:true});
window.addEventListener('resize',()=>toolbar.hidden=true);
export function restoreHighlights(documentToken,saved,canSave){
 root=document.getElementById('document');token=documentToken;records=saved||[];writable=canSave;pending=null;busy=false;toolbar.hidden=true;status.hidden=true;save.disabled=false;remove.disabled=false;
 const missing=paint();if(missing)announce(`${missing} saved highlight${missing===1?' could':'s could'} not be located after the text changed.`);
}
export function highlightsSaved(documentToken,saved){
 if(token!==documentToken)return;
 records=saved;busy=false;save.disabled=false;remove.disabled=false;pending=null;toolbar.hidden=true;window.getSelection()?.removeAllRanges();paint();announce('Highlights saved.');
}
export function highlightSaveFailed(documentToken){
 if(token!==documentToken)return;
 busy=false;save.disabled=false;remove.disabled=false;announce('The highlight could not be saved. Please try again.');
}

export function navigateHighlight(id){
 toolbar.hidden=true;pending=null;window.getSelection()?.removeAllRanges();
 const marks=[...root.querySelectorAll('mark.folio-highlight')].filter(mark=>mark.dataset.highlightIds.split(' ').includes(id));
 if(!marks.length){announce('This marked passage could not be located. The document may have changed.');return;}
 // A mark may be inside collapsed code, metadata, or a nested note.
 for(let parent=marks[0].parentElement;parent&&parent!==root;parent=parent.parentElement){if(parent.tagName==='DETAILS')parent.open=true;}
 requestAnimationFrame(()=>{
  marks[0].scrollIntoView({behavior:'instant',block:'center'});
 });
}
