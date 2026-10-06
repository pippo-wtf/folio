export function popoverPosition(rect,width,height,viewportWidth,viewportHeight){
 const left=Math.max(8,Math.min(rect.left,viewportWidth-width-8));
 const desired=rect.bottom+8+height<=viewportHeight-8?rect.bottom+8:rect.top-height-8;
 return {left,top:Math.max(8,Math.min(desired,viewportHeight-height-8))};
}

// Review UI lives outside the rendered document, so source and anchor text stay exact.
export function createReviewPopover(root,token,before,send,shared,privateInfo){
 const doc=root.ownerDocument,win=doc.defaultView;
 const layer=doc.createElement('div');layer.id='review-accessories';doc.body.append(layer);
 const panel=doc.createElement('section');panel.id='review-popover';panel.hidden=true;panel.setAttribute('role','dialog');panel.setAttribute('aria-label','Comment');doc.body.append(panel);
 let context={enabled:false,mode:'private',threads:[],tasks:[]},active=null,disposed=false,composing=false;
 const drafts=new Map(),submissions=new Map();
 const valid=t=>!disposed&&!!t&&t===token;
 const element=(tag,text,className)=>{const el=doc.createElement(tag);if(text!==undefined)el.textContent=text;if(className)el.className=className;return el;};
 const button=(label,action)=>{const b=element('button',label);b.type='button';b.addEventListener('click',action);return b;};
 const close=()=>{panel.hidden=true;active=null;composing=false;};
 const taskBox=offset=>[...root.querySelectorAll('input[data-task-offset]')].find(box=>Number(box.dataset.taskOffset)===offset);
 const labelFor=state=>state==='done'?'Done':'Open';
 const writable=()=>context.enabled&&!context.busy&&!root.inert;
 function position(){
  for(const b of layer.children){const box=taskBox(Number(b.dataset.offset));if(!box){b.hidden=true;continue;}const r=box.getBoundingClientRect(),line=box.closest('li').getBoundingClientRect();b.hidden=b.dataset.completed!=='true'||r.bottom<0||r.top>win.innerHeight;b.style.left=Math.max(8,Math.min(line.right+8,win.innerWidth-b.offsetWidth-8))+'px';b.style.top=Math.max(8,r.top-3)+'px';}
  if(!active||panel.hidden)return;
  const rect=active.rect();if(!rect||rect.bottom<0||rect.top>win.innerHeight){close();return;}
  const p=popoverPosition(rect,panel.offsetWidth,panel.offsetHeight,win.innerWidth,win.innerHeight);panel.style.left=p.left+'px';panel.style.top=p.top+'px';
 }
 function errorText(value){if(value)panel.append(element('p',String(value),'review-issue'));}
 function header(label){const h=element('header');h.append(element('strong',label),button('Close',close));panel.append(h);}
 function composer(value,submit,onDraft,allowEmpty=false){
  const field=element('textarea');field.rows=3;field.maxLength=20000;field.value=value;field.placeholder='Leave feedback for your agent…';field.setAttribute('aria-label','Comment');
  const shell=element('div',undefined,'review-composer'),actions=element('div',undefined,'review-actions'),save=button(active.kind==='private'?'Save comment':'Send',()=>{if(!save.disabled)submit(field.value);});
  save.className='review-submit';save.dataset.reviewSubmit='';save.setAttribute('aria-label',active.kind==='private'?'Save comment':'Send comment');save.title='Enter to save · Shift+Enter for a new line';
  function update(){save.disabled=active?.pending||context.busy||(!allowEmpty&&!field.value.trim());}
  field.addEventListener('input',()=>{onDraft(field.value);update();});
  field.addEventListener('compositionstart',()=>composing=true);field.addEventListener('compositionend',()=>{composing=false;});
  field.addEventListener('blur',()=>{if(active?.kind==='thread'&&active.needsDraw){active.needsDraw=false;drawThread();}});
  field.addEventListener('keydown',event=>{if(event.key==='Enter'&&!event.shiftKey&&!event.isComposing&&!composing&&event.keyCode!==229){event.preventDefault();if(!save.disabled)submit(field.value);}});
  actions.append(button('Cancel',close),save);shell.append(field,actions);panel.append(shell);update();return field;
 }
 function drawThread(focus=false){
  const thread=context.threads.find(t=>t.id===active?.id);if(!thread){close();return;}
  const previous=panel.querySelector('textarea'),hadFocus=previous===doc.activeElement,caret=previous?[previous.selectionStart,previous.selectionEnd]:null;
  panel.replaceChildren();header('Shared thread');panel.append(element('small','Marked by '+(thread.author||'Unknown author')),element('blockquote',thread.quote));
  const body=element('div',undefined,'review-messages');body.tabIndex=0;body.setAttribute('role','region');body.setAttribute('aria-label','Comments');
  for(const message of thread.messages||[]){const item=element('article');item.append(element('strong',message.author||'Unknown author'),element('p',message.text));if(message.replyTo)item.append(element('small','Reply to '+((thread.messages||[]).find(m=>m.id===message.replyTo)?.author||'comment')));
   const reply=button('Reply',()=>{active.replyTo=message.id;sendDraft(active.draft);drawThread(true);});reply.disabled=!writable();item.append(reply);body.append(item);}
  if(!(thread.messages||[]).length)body.append(element('p','No comments yet.'));panel.append(body);
  const resolve=button(thread.resolved?'Reopen thread':'Resolve thread',()=>send({type:'reviewThreadState',token,id:thread.id,resolved:!thread.resolved}));resolve.disabled=!writable();panel.append(resolve);
  if(active.replyTo){const reply=element('div',undefined,'review-reply');reply.append(element('span','Replying to '+((thread.messages||[]).find(m=>m.id===active.replyTo)?.author||'comment')),button('Cancel reply',()=>{active.replyTo=null;sendDraft(active.draft);drawThread(true);}));panel.append(reply);}
  const field=composer(active.draft,text=>{if(!writable())return;submissions.set(thread.id,{text,sawBusy:false});send({type:'reviewCommentSubmit',token,id:thread.id,text,replyTo:active.replyTo||null});},sendDraft);
  field.disabled=!context.enabled||root.inert;errorText(context.issue);panel.hidden=false;position();if(focus||hadFocus){field.focus({preventScroll:true});if(hadFocus&&caret)field.setSelectionRange(...caret);}
 }
 function sendDraft(text){if(!active)return;active.draft=text;drafts.set(active.id,{text,replyTo:active.replyTo});send({type:'reviewCommentDraft',token,id:active.id,text,replyTo:active.replyTo||null});}
 function drawPrivate(focus=false){
  panel.replaceChildren();header('Private comment');panel.append(element('blockquote',active.info.quote));
  const field=composer(active.draft,text=>{active.draft=text;active.pending=true;send({type:'privateCommentSubmit',token,id:active.id,text});drawPrivate();},text=>{active.draft=text;drafts.set('private:'+active.id,{text});},true);
  field.disabled=!!active.pending;
  if(active.info.comment){const remove=button('Remove comment',()=>{active.draft='';active.pending=true;send({type:'privateCommentSubmit',token,id:active.id,text:''});drawPrivate();});remove.disabled=!!active.pending;panel.append(remove);}
  errorText(active.error);panel.hidden=false;position();if(focus)field.focus({preventScroll:true});
 }
 function openTask(offset,id){
  const box=taskBox(offset);if(!box||!writable())return false;
  box.scrollIntoView({block:'nearest',behavior:'instant'});
  active={kind:'task',id,rect:()=>box.isConnected?box.getBoundingClientRect():null};panel.replaceChildren();header('Shared task');
  const task=context.tasks.find(t=>t.id===id);panel.append(element('p',task?.line||box.closest('li').textContent.trim()));
  for(const state of ['open','done']){const choice=button(labelFor(state),()=>{if(!writable())return;if(context.mode!=='shared')send({type:'reviewModeChanged',token,mode:'shared'});send(id?{type:'reviewTaskState',token,id,state}:{type:'reviewTaskAtOffset',token,before,offset,state});close();});choice.dataset.reviewState=state;choice.setAttribute('aria-pressed',String(task?.states?.length===1&&task.states[0]===state));panel.append(choice);}
  if(task?.states?.length>1)panel.append(element('p','Conflicting updates: choose the current status.'));
  if(task?.status)panel.append(element('p',task.status,'review-task-source-status'));
  if(id&&task?.states?.length===1){const apply=button('Apply status to Markdown',()=>{if(!writable())return;if(context.mode!=='shared')send({type:'reviewModeChanged',token,mode:'shared'});send({type:'reviewTaskApply',token,id});close();});apply.dataset.reviewApply='';apply.disabled=!writable();panel.append(apply);}
  errorText(context.issue);panel.hidden=false;position();return true;
 }
 function reconcileTaskBoxes(){
  if(!context.enabled)return;
  for(const box of root.querySelectorAll('input[data-task-offset]')){
   box.disabled=!!context.busy;
   if(context.busy)continue;
   const matches=context.tasks.filter(task=>task.offset===Number(box.dataset.taskOffset));
   const states=matches.length===1?matches[0].states:[];
   box.checked=states?.length===1?states[0]==='done':box.defaultChecked;
  }
 }
 function accessories(){
  layer.replaceChildren();
  for(const box of root.querySelectorAll('input[data-task-offset]')){const offset=Number(box.dataset.taskOffset),task=context.tasks.find(t=>t.offset===offset),states=task?.states||[];
   const completed=box.checked,author=states.length===1&&states[0]==='done'&&typeof task?.doneBy==='string'?task.doneBy.trim():'';
   const label=author?'Done by '+author:'Done · author not recorded';
   const b=element('span',label);b.className='review-task-accessory';b.dataset.offset=offset;b.dataset.completed=String(completed);b.setAttribute('aria-label',label);layer.append(b);}
  position();
 }
 const outside=event=>{if(!panel.hidden&&!panel.contains(event.target)&&!layer.contains(event.target))close();};
 const key=event=>{if(event.key==='Escape'&&!event.isComposing&&!panel.hidden){event.preventDefault();close();}};
 doc.addEventListener('pointerdown',outside);doc.addEventListener('keydown',key);win.addEventListener('scroll',position,{passive:true});win.addEventListener('resize',position);
 const observer=new win.ResizeObserver(position);observer.observe(root);
 return {
  update(t,value){if(!valid(t)||!value||typeof value!=='object')return false;
   const oldShape=JSON.stringify([context.threads,context.busy,context.issue]);
   context={...value,threads:Array.isArray(value.threads)?value.threads:[],tasks:Array.isArray(value.tasks)?value.tasks:[]};reconcileTaskBoxes();accessories();
   const pending=submissions.get(context.selectedThread);let acknowledged=false;
   if(pending){
    if(context.busy)pending.sawBusy=true;
    if(pending.sawBusy&&!context.busy){
     if(context.draft===''&&!context.issue){
      acknowledged=true;const saved=drafts.get(context.selectedThread);
      if(saved?.text===pending.text)drafts.delete(context.selectedThread);
      if(active?.kind==='thread'&&active.id===context.selectedThread){
       if(active.draft===pending.text){active.draft='';active.replyTo=null;}
       else sendDraft(active.draft);
      }
     }
     submissions.delete(context.selectedThread);
    }
   }
   if(active?.kind==='thread'){
    if(!context.enabled||context.mode!=='shared'){close();return true;}
    const field=panel.querySelector('textarea');
    const changed=oldShape!==JSON.stringify([context.threads,context.busy,context.issue]);
    if(composing||(field===doc.activeElement&&(!acknowledged||active.draft))){
     active.needsDraw=changed||active.needsDraw;
     for(const b of panel.querySelectorAll('button'))if(b.textContent!=='Close')b.disabled=!writable()||(b.hasAttribute('data-review-submit')&&!active.draft.trim());
     let issue=panel.querySelector('.review-issue');if(!issue){issue=element('p',undefined,'review-issue');panel.append(issue);}issue.textContent=context.issue||'';
    }else if(changed||acknowledged)drawThread();
   }
   return true;
  },
  openThread(t,id,focus=false){if(!valid(t)||!context.enabled||!context.threads.some(thread=>thread.id===id))return false;
   if(focus)shared.navigate(t,id);if(!shared.rect(t,id))return false;const draft=drafts.get(id);
   active={kind:'thread',id,rect:()=>shared.rect(t,id),draft:draft?.text??(context.selectedThread===id?(context.draft||''):''),replyTo:draft?draft.replyTo:(context.selectedThread===id?context.replyTo:null)};drawThread(focus);return !panel.hidden;
  },
  openTask(t,id){if(!valid(t))return false;const task=context.tasks.find(t=>t.id===id);return !!task&&openTask(task.offset,id);},
  openPrivate(t,id){if(!valid(t))return false;const info=privateInfo(t,id);if(!info)return false;
   info.reveal();active={kind:'private',id,info,rect:info.rect,draft:drafts.get('private:'+id)?.text??info.comment??''};drawPrivate(true);return !panel.hidden;
  },
  privateResult(t,id,error){if(!valid(t)||active?.kind!=='private'||active.id!==id)return false;active.pending=false;if(error){active.error=String(error);drawPrivate(true);}else{drafts.delete('private:'+id);close();}return true;},
  cleanup(){disposed=true;observer.disconnect();doc.removeEventListener('pointerdown',outside);doc.removeEventListener('keydown',key);win.removeEventListener('scroll',position);win.removeEventListener('resize',position);layer.remove();panel.remove();drafts.clear();}
 };
}
