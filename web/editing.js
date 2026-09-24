// Each edit replaces only one parser-mapped passage. Other source bytes stay intact.
import {parse} from './parser.js';
import {safeLinkDestination,parseCodeSource,formatCodeSource,parseTableSource,formatTableSource,parseImageSource,formatImageSource} from './complex-source.js';
export function replacePassage(source, blocks, id, replacement) {
 const block=blocks.find(b=>b.id===id);
 if(!block||block.start<0||block.end<block.start||block.end>source.length)throw new Error('Invalid passage');
 const old=source.slice(block.start,block.end),newline=source.includes('\r\n')?'\r\n':'\n';
 const suffix=old.match(/(?:\r\n|\n|\r)+$/)?.[0]||'';
 const value=replacement.replace(/\r\n|\r/g,'\n').replace(/\n+$/,'').replace(/\n/g,newline)+suffix;
 const delta=value.length-(block.end-block.start);
 return {source:source.slice(0,block.start)+value+source.slice(block.end),blocks:blocks.map(b=>b.id===id?{...b,end:b.end+delta}:b.start>=block.end?{...b,start:b.start+delta,end:b.end+delta}:b)};
}
const escapeText=s=>s.replace(/\\/g,'\\\\').replace(/([`*_{}\[\]<>#!|~^=&])/g,'\\$1').replace(/(^|\n)(\s*)([-+]|\d+[.)])(?=\s)/g,'$1$2\\$3');
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
  const text=node.textContent;let longest=0;for(const match of text.matchAll(/`+/g))longest=Math.max(longest,match[0].length);
  const ticks='`'.repeat(longest+1);
  const pad=(/^`|`$/.test(text)||(/^ .* $/.test(text)&&/[^ ]/.test(text)))?' ':'';return ticks+pad+text+pad+ticks;
 }
 if(tag==='A'){
  const href=node.getAttribute('href')||'';
  if(!safeLinkDestination(href))return inner();
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

function documentWordCount(root){
 const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
 const blockSelector='p,h1,h2,h3,h4,h5,h6,li,th,td,pre,blockquote,figcaption,.edit-passage,.source-preserved';
 let text='',previous=null,node;
 while((node=walker.nextNode())){
  const parent=node.parentElement;
  if(!parent||parent.closest('button,summary,.edit-tail,.image-fallback,[hidden],[aria-hidden="true"],script,style'))continue;
  const block=parent.closest(blockSelector)||root;
  if(previous&&block!==previous)text+=' ';
  text+=node.nodeValue;
  previous=block;
 }
 return (text.match(/\S+/g)||[]).length;
}

let activeCleanup=()=>{};
export function setupEditing(initial,initialBlocks,complexBlocks,assetPrefix,token,enabled,send){
 activeCleanup();activeCleanup=()=>{};document.getElementById('format-bar')?.remove();
 let source=initial,active=null,range=null,structuredEditSerial=0;
 const root=document.getElementById('document'),original=new WeakMap(),protectedNodes=[];
 const nodes=[...root.childNodes],ordinaryById=new Map(initialBlocks.map(block=>[block.id,block])),complexById=new Map(complexBlocks.map(block=>[block.id,block]));let pending=[],offset=0;
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
  const complex=node.nodeType===1&&complexById.get(node.dataset.complex);
  if(complex){
   preserve(complex.start);
   const host=document.createElement('div');host.className='source-preserved complex-passage';host.contentEditable='false';host.dataset.complex=complex.id;host.dataset.kind=complex.kind;
   node.removeAttribute('data-complex');host.append(node);
   if(enabled){const button=document.createElement('button');button.type='button';button.className='complex-edit-button';button.innerHTML='<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m16 3 5 5-12 12-6 1 1-6Z"/><path d="m14 5 5 5"/></svg>';button.setAttribute('aria-label','Edit '+complex.kind);button.title='Edit '+complex.kind;host.append(button);}
   original.set(host,{raw:initial.slice(complex.start,complex.end),locked:true,kind:complex.kind});protectedNodes.push(host);fragment.append(host);offset=complex.end;continue;
  }
  const block=node.nodeType===1&&ordinaryById.get(node.dataset.edit);
  if(!block){pending.push(node);continue;}
  preserve(block.start);
  const host=document.createElement('div');host.className='edit-passage';host.dataset.edit=block.id;
  node.removeAttribute('data-edit');node.removeAttribute('contenteditable');host.append(node);
  original.set(host,{raw:initial.slice(block.start,block.end),baseline:serialize(host)});
  fragment.append(host);offset=block.end;
 }
 preserve(initial.length);root.replaceChildren(fragment);
 // Identical wrappers in both modes preserve column geometry and block spacing.
 // Reading stops before registering input handlers or making anything editable.
 if(!enabled){root.removeAttribute('contenteditable');root.setAttribute('aria-label','Document');return;}
 // Measure the first visible line, so controls stay aligned at every font size.
 const positionControls=()=>root.querySelectorAll('.complex-passage').forEach(host=>{
  const first=host.querySelector('th,summary,img:not([hidden]),.image-fallback:not([hidden])')||host.firstElementChild;
  if(!first)return;
  const bounds=first.getBoundingClientRect(),style=getComputedStyle(first);
  const center=first.tagName==='IMG'?bounds.top+18:bounds.top+parseFloat(style.paddingTop)+parseFloat(style.lineHeight)/2;
  host.style.setProperty('--edit-control-top',(center-host.getBoundingClientRect().top-18)+'px');
 });
 const observer=new ResizeObserver(positionControls);observer.observe(root);
 root.querySelectorAll('.complex-passage').forEach(host=>observer.observe(host));
 document.fonts.ready.then(()=>{if(root.isContentEditable)positionControls();});
 requestAnimationFrame(positionControls);
 root.contentEditable='true';root.spellcheck=true;root.setAttribute('role','textbox');root.setAttribute('aria-multiline','true');root.setAttribute('aria-label','Document editor');
 root.querySelectorAll('.edit-passage code').forEach(code=>{
  code.spellcheck=false;code.setAttribute('autocorrect','off');code.setAttribute('autocapitalize','off');code.setAttribute('writingsuggestions','false');
 });
 const tail=document.createElement('div');tail.className='edit-passage edit-tail';tail.dataset.edit='tail';tail.innerHTML='<p><br></p>';root.append(tail);
 const bar=document.createElement('div');bar.id='format-bar';bar.setAttribute('role','toolbar');bar.setAttribute('aria-label','Text formatting');
 bar.innerHTML='<div class="format-actions"><button data-block="p">Body</button><button data-block="h1">Heading 1</button><button data-block="h2">Heading 2</button><button data-command="insertUnorderedList">List</button><button data-command="insertOrderedList">Numbered</button><button data-block="blockquote">Quote</button><button data-command="bold"><b>Bold</b></button><button data-command="italic"><i>Italic</i></button><button data-command="strikeThrough"><s>Strike</s></button><button data-link>Link</button></div><span id="word-count"></span>';
 document.body.append(bar);
 const count=()=>{bar.querySelector('#word-count').textContent=documentWordCount(root).toLocaleString()+' words';};count();
 function commit(passage='document'){
  if(protectedNodes.some(node=>node.parentNode!==root)){
   send({type:'editingRejected',token});return;
  }
  const newline=initial.includes('\r\n')?'\r\n':'\n';
  const next=serializeDocument(root.childNodes,original,tail,newline);
  if(next!==source){const before=source;source=next;send({type:'editDocument',token,before,text:source,passage});}
  if(!panel)count();
 }
 const select=()=>{
  const selection=getSelection();if(!selection?.rangeCount)return;
  const r=selection.getRangeAt(0);
  if(root.contains(r.startContainer)&&root.contains(r.endContainer)){active=root;range=r.cloneRange();}
 };
 const blocked=r=>protectedNodes.some(node=>r.intersectsNode(node));
 const notice=()=>send({type:'copyNotice',text:'This selection includes a protected block. Use its Edit control or Source to change it.'});
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
 let panel=null,returnFocus=null;
 const closePanel=()=>{
  const wasOpen=!!panel;panel?.remove();panel=null;root.inert=false;bar.inert=false;
  const highlights=document.getElementById('highlight-tools');if(highlights)highlights.inert=false;
  if(wasOpen)send({type:'complexEditorState',token,active:false});
  if(wasOpen)count();
  if(returnFocus?.isConnected)returnFocus.focus({preventScroll:true});returnFocus=null;
 };
 function showPanel(trigger,title,build,save){
  closePanel();returnFocus=trigger;
  panel=document.createElement('div');panel.id='complex-editor';panel.setAttribute('role','dialog');panel.setAttribute('aria-modal','true');panel.setAttribute('aria-label',title);
  const heading=document.createElement('h2');heading.textContent=title;panel.append(heading);
  const fields=document.createElement('div');fields.className='complex-fields';panel.append(fields);
  const error=document.createElement('p');error.className='complex-error';error.setAttribute('role','alert');error.hidden=true;panel.append(error);
  const actions=document.createElement('div');actions.className='complex-actions';panel.append(actions);
  const cancel=document.createElement('button');cancel.type='button';cancel.textContent='Cancel';cancel.addEventListener('click',closePanel);actions.append(cancel);
  const apply=document.createElement('button');apply.type='button';apply.textContent='Apply';apply.className='complex-apply';apply.addEventListener('click',()=>{
   try{const message=save();if(message){error.textContent=message;error.hidden=false;}else closePanel();}
   catch{error.textContent='This block could not be updated. Its source is unchanged.';error.hidden=false;}
  });actions.append(apply);
  panel.addEventListener('keydown',event=>{
   if(event.key==='Escape'){event.preventDefault();closePanel();return;}
   if(event.key==='Tab'){
    const focusable=[...panel.querySelectorAll('input,textarea,button')].filter(control=>!control.disabled);
    if(!focusable.length)return;
    if(event.shiftKey&&document.activeElement===focusable[0]){event.preventDefault();focusable.at(-1).focus();}
    else if(!event.shiftKey&&document.activeElement===focusable.at(-1)){event.preventDefault();focusable[0].focus();}
   }
  });
  document.body.append(panel);build(fields);
  root.inert=true;bar.inert=true;
  const highlights=document.getElementById('highlight-tools');if(highlights)highlights.inert=true;
  send({type:'complexEditorState',token,active:true});
  fields.querySelector('input,textarea,button')?.focus();
 }
 const field=(container,label,value,multiline=false)=>{
  const wrapper=document.createElement('label'),caption=document.createElement('span');caption.textContent=label;wrapper.append(caption);
  const control=document.createElement(multiline?'textarea':'input');control.value=value;
  // These fields write exact Markdown/code. WebKit must not rewrite typed syntax.
  control.spellcheck=false;control.autocomplete='off';control.setAttribute('autocorrect','off');control.setAttribute('autocapitalize','off');control.setAttribute('writingsuggestions','false');
  wrapper.append(control);container.append(wrapper);return control;
 };
 function openComplex(button){
  const host=button.closest('.complex-passage'),record=original.get(host),raw=record.raw;
  const parsed=record.kind==='code'?parseCodeSource(raw):record.kind==='table'?parseTableSource(raw):parseImageSource(raw);
  if(!parsed){notice();return;}
  if(record.kind==='code'){
   let language,text;
   showPanel(button,'Edit code',fields=>{language=field(fields,'Language',parsed.language);text=field(fields,'Code',parsed.text,true);},()=>{
    if(language.value===parsed.language&&text.value===parsed.text)return null;
    const next=formatCodeSource(parsed,language.value.trim(),text.value);
    if(!next)return 'Use a short language name and valid code text.';
    return applyComplex(host,record,next,'code');
   });return;
  }
  if(record.kind==='image'){
   let alt,path;
   showPanel(button,'Edit image',fields=>{alt=field(fields,'Alt text',parsed.alt);path=field(fields,'Local image path',parsed.path);},()=>{
    if(alt.value===parsed.alt&&path.value===parsed.path)return null;
    const next=formatImageSource(parsed,alt.value,path.value);
    if(!next)return 'Use a relative local image path and alt text without line breaks or ].';
    return applyComplex(host,record,next,'image');
   });return;
  }
  let rows=parsed.rows.map(row=>[...row]),grid;
  showPanel(button,'Edit table',fields=>{
   grid=document.createElement('div');grid.className='complex-table-grid';fields.append(grid);
   const controls=document.createElement('div');controls.className='complex-table-actions';fields.append(controls);
   const action=(label,operation)=>{const control=document.createElement('button');control.type='button';control.textContent=label;control.addEventListener('click',()=>{operation();renderGrid();});controls.append(control);};
   action('Add row',()=>{if(rows.length<200)rows.push(Array(rows[0].length).fill(''));});
   action('Add column',()=>{if(rows[0].length<30)rows.forEach(row=>row.push(''));});
   action('Remove last column',()=>{if(rows[0].length>1)rows.forEach(row=>row.pop());});
   function renderGrid(){
    grid.replaceChildren();
    rows.forEach((row,r)=>{
     const line=document.createElement('div');line.className='complex-table-row';grid.append(line);
     row.forEach((value,c)=>{const input=field(line,(r?'Row '+r:'Header')+' column '+(c+1),value);input.addEventListener('input',()=>{rows[r][c]=input.value;});});
     if(r){const remove=document.createElement('button');remove.type='button';remove.textContent='Remove row '+r;remove.addEventListener('click',()=>{rows.splice(r,1);renderGrid();grid.querySelector('input')?.focus();});line.append(remove);}
    });
   }
   renderGrid();
  },()=>{
   if(JSON.stringify(rows)===JSON.stringify(parsed.rows))return null;
   const next=formatTableSource(parsed,rows);
   if(!next)return 'This table is too large or has an invalid shape.';
   return applyComplex(host,record,next,'table');
  });
 }
 function applyComplex(host,record,next,kind){
  const rendered=parse(next,assetPrefix,false),selector=kind==='code'?'.code-block':kind==='table'?'.table-scroll':'.image-frame';
  const scratch=document.createElement('div');scratch.innerHTML=rendered.html;
  const replacement=scratch.querySelector(selector),previous=host.querySelector(selector);
  if(!replacement||!previous)return 'The edited block could not be rendered. Its source is unchanged.';
  if(kind==='code'){
   const oldCopy=previous.querySelector('[data-copy]'),newCopy=replacement.querySelector('[data-copy]');
   if(oldCopy&&newCopy){newCopy.dataset.copy=oldCopy.dataset.copy;window.Folio?.updateCode?.(Number(oldCopy.dataset.copy),rendered.codeBlocks[0]);}
  }
  if(kind==='image')replacement.querySelector('img')?.addEventListener('error',event=>{event.target.hidden=true;event.target.nextElementSibling.hidden=false;});
  host.replaceChild(replacement,previous);record.raw=next;commit('complex:'+token+':'+host.dataset.complex+':'+(++structuredEditSerial));return null;
 }
 function openLink(anchor){
  const host=anchor.closest('.edit-passage');if(!host)return;
  const labelBefore=anchor.textContent,urlBefore=anchor.getAttribute('href')||'';
  let label,url;
  showPanel(anchor,'Edit link',fields=>{label=field(fields,'Label',labelBefore);url=field(fields,'Destination',urlBefore);},()=>{
   if(label.value===labelBefore&&url.value===urlBefore)return null;
   const safe=safeLinkDestination(url.value);
   if(!safe)return 'Use a safe web, email, heading, or relative destination without spaces.';
   if(!label.value.trim()||/[\r\n]/.test(label.value))return 'Enter a one-line link label.';
   anchor.textContent=label.value;anchor.setAttribute('href',safe);commit('link:'+token+':'+host.dataset.edit+':'+(++structuredEditSerial));return null;
  });
 }
 const rootClick=event=>{
  const button=event.target.closest('.complex-edit-button');if(button){event.preventDefault();event.stopPropagation();openComplex(button);return;}
  const anchor=event.target.closest('a');if(anchor&&root.contains(anchor)&&!event.metaKey&&anchor.closest('.edit-passage')){event.preventDefault();event.stopPropagation();openLink(anchor);}
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
   field=document.createElement('input');field.type='url';field.placeholder='https://… · Enter to add';field.setAttribute('aria-label','Link address');
   field.spellcheck=false;field.autocomplete='off';field.setAttribute('autocorrect','off');field.setAttribute('autocapitalize','off');field.setAttribute('writingsuggestions','false');bar.append(field);field.focus();
   field.addEventListener('keydown',event=>{if(event.key==='Escape'){field.remove();active.focus();}if(event.key==='Enter'){
    const url=safeLinkDestination(field.value);if(!url)return;
    active.focus();getSelection().removeAllRanges();getSelection().addRange(range);document.execCommand('createLink',false,url);commit(active);field.remove();
   }});return;
  }
  document.execCommand(button.dataset.block?'formatBlock':button.dataset.command,false,button.dataset.block||null);commit(active);select();
 });
 root.addEventListener('keydown',keydown);root.addEventListener('input',input);root.addEventListener('paste',paste);root.addEventListener('drop',drop);root.addEventListener('beforeinput',beforeinput);root.addEventListener('click',rootClick);document.addEventListener('selectionchange',select);
 activeCleanup=()=>{observer.disconnect();closePanel();root.setAttribute('aria-label','Document');root.removeAttribute('contenteditable');root.removeAttribute('role');root.removeAttribute('aria-multiline');root.removeEventListener('keydown',keydown);root.removeEventListener('input',input);root.removeEventListener('paste',paste);root.removeEventListener('drop',drop);root.removeEventListener('beforeinput',beforeinput);root.removeEventListener('click',rootClick);document.removeEventListener('selectionchange',select);};
}
