import {setupEditing} from './editing.js';
import {parse} from './parser.js';
import {applyLayout} from './layout.js';
import {restoreHighlights,highlightSelection,highlightsSaved,highlightSaveFailed,navigateHighlight} from './highlights.js';
import {renderDiagrams} from './diagrams.js';
let codes=[],renderVersion=0,positionToken='',positionTimer;
let restoring=false,diagramWork=Promise.resolve();
const send=message=>window.webkit?.messageHandlers.folio.postMessage(message);
window.Folio={
 highlightSelection,highlightsSaved,highlightSaveFailed,navigateHighlight,
 focusTask(offset){document.querySelector(`input[data-task-offset="${Number(offset)}"]`)?.focus({preventScroll:true});},
 updateCode(index,text){if(Number.isInteger(index)&&index>=0&&index<codes.length)codes[index]=text;},
 finishExport(){
  document.querySelectorAll('.print-keep').forEach(el=>el.replaceWith(...el.childNodes));
  const root=document.getElementById('document');if(root.dataset.restoreEditing){root.contentEditable='true';delete root.dataset.restoreEditing;}
  document.querySelectorAll('#format-bar button').forEach(button=>button.disabled=false);
 },
 async preparePrint(){
  const version=renderVersion;
  await diagramWork;await document.fonts.ready;
  if(version!==renderVersion)return;
  const root=document.getElementById('document');if(root.isContentEditable){root.dataset.restoreEditing='true';root.contentEditable='false';}
  document.querySelectorAll('#format-bar button').forEach(button=>button.disabled=true);
  for(const heading of document.querySelectorAll('#document h1,#document h2,#document h3,#document h4,#document h5,#document h6')){
   if(heading.parentElement.classList.contains('print-keep'))continue;
   const block=heading.closest('.edit-passage')||heading;
   const next=block.nextElementSibling,paragraph=next?.classList.contains('edit-passage')?next.firstElementChild:next;
   if(paragraph?.tagName==='P'&&next.textContent.length<1800&&!next.classList.contains('edit-tail')){
    const group=document.createElement('div');group.className='print-keep';block.before(group);
    // Include source-spacing comments so export teardown restores exact DOM order.
    let current=block;while(current){const following=current.nextSibling;group.append(current);if(current===next)break;current=following;}
   }
  }
  send({type:'printReady',token:positionToken});
 },
 copyFormatted(){
  const selection=window.getSelection();
  if(!selection||selection.isCollapsed||!selection.rangeCount){send({type:'copyNotice',text:'Select a passage on the page first.'});return;}
  const range=selection.getRangeAt(0),root=document.getElementById('document');
  if(!root.contains(range.commonAncestorContainer))return;
  const plain=selection.toString();
  if(plain.length>100000){send({type:'copyNotice',text:'Select a shorter passage to copy with formatting.'});return;}
  const box=document.createElement('div');box.append(range.cloneContents());
  box.querySelectorAll('button,script,style,summary').forEach(el=>el.remove());
  box.querySelectorAll('*').forEach(el=>{
   for(const attr of [...el.attributes])if(!['href','colspan','rowspan','start'].includes(attr.name))el.removeAttribute(attr.name);
   if(el.hasAttribute('href')&&!/^(https?:|#)/i.test(el.getAttribute('href')))el.removeAttribute('href');
   if(el.tagName==='MARK')el.style.backgroundColor='rgba(44,255,5,0.5)';
   if(['CODE','PRE'].includes(el.tagName))el.style.fontFamily='Menlo,monospace';
   if(el.tagName==='TD'||el.tagName==='TH')el.style.cssText='padding:8px;border-bottom:1px solid #ddd;text-align:left';
  });
  box.style.cssText='font-family:Georgia,serif;font-size:18px;line-height:1.6;color:#191919';
  send({type:'copyFormatted',text:plain,html:box.outerHTML});
 },
 render(markdown,assetPrefix,highlightToken,highlights,canSaveHighlights,position,editing=false){
  positionToken=highlightToken;restoring=true;
  const old=window.scrollY,oldHeading=[...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(e=>e.getBoundingClientRect().top<=80).pop();
  const anchor=oldHeading?{id:oldHeading.id,offset:oldHeading.getBoundingClientRect().top}:null;
  const version=++renderVersion;
  const result=parse(markdown,assetPrefix,true); codes=result.codeBlocks;
  const previousHost=document.activeElement===document.getElementById('document')?document.getElementById('document'):null;
  let caret=null;
  if(previousHost&&getSelection()?.rangeCount){
   const selection=getSelection(),range=document.createRange();range.selectNodeContents(previousHost);
   if(previousHost.contains(selection.focusNode)){range.setEnd(selection.focusNode,selection.focusOffset);caret={id:previousHost.dataset.edit,offset:range.toString().length};}
  }
  document.getElementById('document').innerHTML=result.html;
  document.querySelectorAll('img').forEach(img=>img.addEventListener('error',()=>{img.hidden=true;img.nextElementSibling.hidden=false;}));
  setupEditing(markdown,result.blocks,result.complexBlocks,assetPrefix,highlightToken,editing,send);
  restoreHighlights(highlightToken,highlights,canSaveHighlights);
  if(caret&&editing){
   const host=document.getElementById('document');
   if(host){host.focus({preventScroll:true});const walker=document.createTreeWalker(host,NodeFilter.SHOW_TEXT);let node,last,offset=caret.offset;
    while((node=walker.nextNode())){last=node;if(offset<=node.length)break;offset-=node.length;}
    const range=document.createRange();if(last){range.setStart(last,Math.min(offset,last.length));}else{range.selectNodeContents(host);}range.collapse(true);getSelection().removeAllRanges();getSelection().addRange(range);
   }
  }
  send({type:'outline',headings:result.headings});
  const restore=()=>{
   if(version!==renderVersion)return;
   const destination=position?document.getElementById(position.heading):anchor&&document.getElementById(anchor.id);
   const y=position?(destination?window.scrollY+destination.getBoundingClientRect().top-position.offset:position.fraction*Math.max(0,document.documentElement.scrollHeight-innerHeight)):(destination?window.scrollY+destination.getBoundingClientRect().top-anchor.offset:old);
   window.scrollTo(0,y);restoring=false;
  };
  requestAnimationFrame(restore);
  diagramWork=renderDiagrams(result.diagrams,()=>version===renderVersion);
  diagramWork.then(()=>{if(position)restore();});
 },
 navigate(id){requestAnimationFrame(()=>document.getElementById(id)?.scrollIntoView({behavior:'instant',block:'start'}));},
 appearance(mode,zoom,settings){document.documentElement.dataset.appearance=mode;applyLayout(settings,zoom);}
};
document.addEventListener('click',event=>{
 const button=event.target.closest('button[data-copy]');
 if(button){const index=Number(button.dataset.copy);if(codes[index]!==undefined){send({type:'copyCode',text:codes[index]});button.textContent='Copied';setTimeout(()=>button.textContent='Copy',1400);}}
 const a=event.target.closest('a');
 if(a?.isContentEditable&&!event.metaKey){event.preventDefault();return;}
 if(a?.dataset.note!==undefined){event.preventDefault();const target=a.dataset.note;if(target.startsWith('#')){const title=target.slice(1);const heading=[...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].find(h=>h.textContent===title||h.id===title);heading?.scrollIntoView({block:'start'});}else send({type:'noteLink',target});return;}
 if(a){const href=a.getAttribute('href')||'';event.preventDefault();if(href.startsWith('#')){try{window.Folio.navigate(decodeURIComponent(href.slice(1)));}catch{}}else{send({type:'link',url:href});}}
});
send({type:'ready'});

(function () {
  if (document.getElementById('reading-scroll-indicator')) return;

  var indicator = document.createElement('div');
  indicator.id = 'reading-scroll-indicator';
  indicator.setAttribute('aria-hidden', 'true');
  document.documentElement.appendChild(indicator);

  var hideTimer = null;
  var rafId = null;

  function docHeight() {
    var d = document.documentElement;
    var b = document.body;
    return Math.max(
      d.scrollHeight, d.offsetHeight, d.clientHeight,
      b ? b.scrollHeight : 0, b ? b.offsetHeight : 0
    );
  }

  function updateGeometry() {
    var viewportH = window.innerHeight;
    var contentH = docHeight();
    if (contentH <= viewportH) {
      indicator.style.height = '0px';
      indicator.style.transform = 'translateY(0px)';
      return;
    }
    var thumbH = Math.max(28, Math.round((viewportH / contentH) * viewportH));
    var maxScroll = contentH - viewportH;
    var scrollY = window.scrollY || window.pageYOffset || 0;
    var ratio = maxScroll > 0 ? scrollY / maxScroll : 0;
    var trackRange = viewportH - thumbH;
    var y = Math.max(0, Math.min(trackRange, ratio * trackRange));

    indicator.style.height = thumbH + 'px';
    indicator.style.transform = 'translateY(' + y + 'px)';
  }

  function showIndicator() {
    indicator.classList.add('scrolling');
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = setTimeout(function () {
      indicator.classList.remove('scrolling');
      hideTimer = null;
    }, 700);
  }

  function onScroll() {
    if (rafId) return;
    rafId = requestAnimationFrame(function () {
      rafId = null;
      updateGeometry();
      showIndicator();
    });
  }

  window.addEventListener('scroll', onScroll, { passive: true });

  var resizeObserver = null;
  if (typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(function () {
      updateGeometry();
    });
    resizeObserver.observe(document.documentElement);
    if (document.body) resizeObserver.observe(document.body);
  } else {
    window.addEventListener('resize', updateGeometry, { passive: true });
  }

  updateGeometry();
})();

window.addEventListener('scroll',()=>{
 if(restoring)return;
 clearTimeout(positionTimer);const token=positionToken;
 positionTimer=setTimeout(()=>{
  if(token!==positionToken||restoring)return;
  const heading=[...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(e=>e.getBoundingClientRect().top<=80).pop();
  send({type:'readingPosition',token,position:{heading:heading?.id||'',offset:heading?.getBoundingClientRect().top||0,fraction:Math.max(0,Math.min(1,scrollY/Math.max(1,document.documentElement.scrollHeight-innerHeight)))}});
 },180);
},{passive:true});

window.addEventListener('afterprint',()=>window.Folio.finishExport());
