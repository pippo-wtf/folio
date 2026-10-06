import {anchor,locate} from './highlight-anchors.js';

const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const revision=/^[0-9a-f]{64}$/;
// Shared anchors use the private rendered-text coordinate space, never source offsets.
export function locateSharedAnchor(text,record){
 if(!record||typeof record.id!=='string'||!uuid.test(record.id)||!Number.isSafeInteger(record.start)||record.start<0||
    typeof record.quote!=='string'||!record.quote.trim()||record.quote.length>20000||
    typeof record.prefix!=='string'||record.prefix.length>64||typeof record.suffix!=='string'||record.suffix.length>64||
    typeof record.rawSourceRevision!=='string'||!revision.test(record.rawSourceRevision)||typeof record.decodedSourceRevision!=='string'||!revision.test(record.decodedSourceRevision))return {status:'invalid'};
 const found=locate(text,record);
 if(found)return {status:'located',...found};
 return {status:text.includes(record.quote)?'ambiguous':'missing'};
}

export function locateSharedRecords(text,records){
 const canonicalID=record=>typeof record?.id==='string'?record.id.toLowerCase():null;
 const ids=new Set(),duplicates=new Set();
 for(const record of records){const id=canonicalID(record);if(ids.has(id))duplicates.add(id);ids.add(id);}
 return records.map(record=>({id:typeof record?.id==='string'?record.id:'',...(duplicates.has(canonicalID(record))?{status:'invalid'}:locateSharedAnchor(text,record))}));
}

export function createSharedReview(root,token,send){
 const doc=root.ownerDocument,win=doc.defaultView;
 let records=[],ranges=new Map(),names=[],composing=false,changing=false,cancelled=false,active=false,timer;
 const style=doc.createElement('style');style.dataset.folioSharedReview='';
 const entries=()=>{
  const values=[];
  // Keep this exclusion list equal to private highlights: both anchor the same text.
  const walker=doc.createTreeWalker(root,win.NodeFilter.SHOW_TEXT,{acceptNode:n=>n.parentElement.closest('button,summary,script,style,.diagram-preview,.math-preview,.katex')?win.NodeFilter.FILTER_REJECT:win.NodeFilter.FILTER_ACCEPT});
  let node,start=0;while((node=walker.nextNode())){values.push({node,start,end:start+node.length});start+=node.length;}
  return values;
 };
 const clear=()=>{for(const name of names)win.CSS?.highlights?.delete(name);names=[];ranges.clear();};
 const deferred=()=>composing||changing||root.inert||!!doc.getElementById('complex-editor')||!!doc.querySelector('#format-bar input');
 function refresh(){
  clear();const nodes=entries(),text=nodes.map(e=>e.node.data).join('');
  const statuses=locateSharedRecords(text,records);
  let painting=deferred()?'deferred':typeof win.Highlight==='function'&&win.CSS?.highlights?'painted':'unsupported';
  if(painting==='painted'){
   try{
    if(!style.isConnected)doc.head.append(style);
    const rules=[];
    for(const result of statuses){
     if(result.status!=='located')continue;
     const first=nodes.find(e=>e.start<=result.start&&e.end>result.start),last=nodes.find(e=>e.start<result.end&&e.end>=result.end);
     if(!first||!last)continue;
     const range=doc.createRange();range.setStart(first.node,result.start-first.start);range.setEnd(last.node,result.end-last.start);
     const name='folio-shared-'+result.id.toLowerCase();
     win.CSS.highlights.set(name,new win.Highlight(range));names.push(name);ranges.set(result.id,range);
     rules.push(`::highlight(${name}){background-color:color-mix(in srgb,var(--accent) 28%,transparent);color:var(--ink);text-decoration:underline;text-decoration-color:var(--accent);text-decoration-thickness:2px}`);
    }
    const css=rules.join('\n');if(style.textContent!==css)style.textContent=css;
   }catch{clear();painting='unsupported';}
  }
  const result={accepted:true,token,painting,records:statuses};
  send({type:'sharedReviewAnchors',...result});return result;
 }
 const schedule=()=>{clearTimeout(timer);timer=setTimeout(()=>{changing=false;if(!cancelled&&active)refresh();},0);};
 const compositionStart=()=>{composing=true;clear();};
 const compositionEnd=()=>{composing=false;schedule();};
 // Live Ranges track edits. Clear before input so a changed quote never paints as saved.
 const beforeInput=()=>{changing=true;clear();schedule();};
 const input=()=>{changing=false;schedule();};
 const click=event=>{
  if(deferred()||!win.getSelection()?.isCollapsed)return;
  const hits=[];
  for(const [id,range] of ranges){if([...range.getClientRects()].some(r=>event.clientX>=r.left&&event.clientX<=r.right&&event.clientY>=r.top&&event.clientY<=r.bottom))hits.push(id);}
  if(hits.length){hits.sort();send({type:'sharedHighlightClicked',token,id:hits[0],ids:hits});}
 };
 root.addEventListener('compositionstart',compositionStart);root.addEventListener('compositionend',compositionEnd);
 root.addEventListener('beforeinput',beforeInput);root.addEventListener('input',input);root.addEventListener('click',click);
 const observer=new win.MutationObserver(()=>{clear();schedule();});observer.observe(root,{subtree:true,childList:true,characterData:true,attributes:true});
 // Inline link editing lives outside the document; Escape removes its input only.
 const bar=doc.getElementById('format-bar');if(bar)observer.observe(bar,{subtree:true,childList:true});
 return {
  update(documentToken,sharedRecords){
   if(cancelled||documentToken!==token)return {accepted:false,token:documentToken,painting:'stale',records:[]};
   if(!Array.isArray(sharedRecords))return {accepted:false,token,painting:'invalid',records:[]};
   active=true;records=sharedRecords.map(r=>r&&typeof r==='object'?{...r}:r);return refresh();
  },
  preview(documentToken,previewRecords){
   if(cancelled||!documentToken||documentToken!==token)return {accepted:false,token:documentToken,records:[],reason:'stale'};
   if(!Array.isArray(previewRecords))return {accepted:false,token,records:[],reason:'invalid'};
   if(deferred())return {accepted:false,token,records:[],reason:'deferred'};
   return {accepted:true,token,records:locateSharedRecords(entries().map(e=>e.node.data).join(''),previewRecords)};
  },
  selection(documentToken){
   if(cancelled||documentToken!==token||deferred())return null;
   const selection=win.getSelection();if(!selection?.rangeCount||selection.isCollapsed)return null;
   const range=selection.getRangeAt(0);if(!root.contains(range.startContainer)||!root.contains(range.endContainer))return null;
   const nodes=entries();let start=null,end=null;
   for(const e of nodes){if(!range.intersectsNode(e.node))continue;
    const a=e.node===range.startContainer?range.startOffset:0,b=e.node===range.endContainer?range.endOffset:e.node.length;
    if(b>a){if(start===null)start=e.start+a;end=e.start+b;}
   }
   if(start===null)return null;
   const value=anchor(nodes.map(e=>e.node.data).join(''),start,end,'');if(!value)return null;
   const {id,...result}=value;return {token,...result};
  },
  rect(documentToken,id){
   if(cancelled||documentToken!==token||deferred())return null;
   const record=records.find(r=>r.id===id);if(!record)return null;
   const nodes=entries(),state=locateSharedAnchor(nodes.map(e=>e.node.data).join(''),record);if(state.status!=='located')return null;
   const first=nodes.find(e=>e.start<=state.start&&e.end>state.start),last=nodes.find(e=>e.start<state.end&&e.end>=state.end);if(!first||!last)return null;
   const range=doc.createRange();range.setStart(first.node,state.start-first.start);range.setEnd(last.node,state.end-last.start);return range.getBoundingClientRect();
  },
  navigate(documentToken,id){
   if(cancelled||documentToken!==token)return {status:'stale'};
   if(deferred())return {status:'deferred'};
   const state=refresh().records.find(r=>r.id===id);if(!state)return {status:'missing'};
   if(state.status!=='located')return state;
   // Navigation also works on engines without the Custom Highlight API.
   const nodes=entries(),target=nodes.find(e=>e.start<=state.start&&e.end>state.start)?.node.parentElement;
   if(!target)return {id,status:'missing'};
   for(let el=target;el&&el!==root;el=el.parentElement){if(el.tagName==='DETAILS')el.open=true;}
   target.scrollIntoView({behavior:'instant',block:'center'});return state;
  },
  cleanup(){cancelled=true;clearTimeout(timer);observer.disconnect();clear();style.remove();
   root.removeEventListener('compositionstart',compositionStart);root.removeEventListener('compositionend',compositionEnd);
   root.removeEventListener('beforeinput',beforeInput);root.removeEventListener('input',input);root.removeEventListener('click',click);
  }
 };
}
