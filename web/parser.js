import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import tasks from 'markdown-it-task-lists';
import deflist from 'markdown-it-deflist';
import mark from 'markdown-it-mark';
import sub from 'markdown-it-sub';
import sup from 'markdown-it-sup';
import texmath from 'markdown-it-texmath';
import katex from 'katex';
import hljs from 'highlight.js/lib/common';
import {writingExtensions} from './extensions.js';
const mathOptions={trust:false,strict:'error',throwOnError:true,maxExpand:500,maxSize:20,output:'htmlAndMathml'};
const mathEngine={renderToString(source,options){
 if(source.length>10000)throw new Error('Equation exceeds the size limit.');
 return katex.renderToString(source,{...options,...mathOptions,macros:{}});
}};
export function parse(markdown, assetPrefix='folio-asset://unavailable/', editing=false) {
 const md=new MarkdownIt({html:false,linkify:true,typographer:false}).use(footnote).use(tasks,{enabled:false,label:false}).use(deflist).use(mark).use(sub).use(sup).use(writingExtensions).use(texmath,{engine:mathEngine,delimiters:['dollars','brackets'],katexOptions:{...mathOptions}});
 const headings=[], images=[], codeBlocks=[], diagrams=[], used=new Set();
 const originalSource=markdown, blocks=[];
 const metadata = markdown.match(/^---\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)(?:\r?\n|$)/);
 if(metadata) markdown=markdown.slice(metadata[0].length);
 md.core.ruler.after('inline','folio-callouts',state=>{
  const stack=[];
  for(let i=0;i<state.tokens.length;i++){
   const t=state.tokens[i];
   if(t.type==='blockquote_open'){
    const paragraph=state.tokens[i+1],inline=state.tokens[i+2];
    const match=paragraph?.type==='paragraph_open' && inline?.type==='inline' && inline.content.match(/^\[!([\w-]+)\]([+-])?(?:[ \t]+([^\n]*))?(?:\n|$)/);
    if(!match){stack.push(null);continue;}
    const type=match[1].toLowerCase();
    const aliases={hint:'tip',important:'tip',caution:'warning',attention:'warning',error:'danger',failure:'danger',fail:'danger',bug:'danger',done:'success',check:'success'};
    const kind=aliases[type]||(['tip','warning','danger','success'].includes(type)?type:'note');
    t.type='folio_callout_open';t.meta={kind,fold:match[2],title:match[3]||type.charAt(0).toUpperCase()+type.slice(1)};
    stack.push(t.meta);
    inline.content=inline.content.slice(match[0].length);inline.children=[];
    md.inline.parse(inline.content,md,state.env,inline.children);
    if(!inline.content){paragraph.hidden=true;state.tokens[i+3].hidden=true;}
   }else if(t.type==='blockquote_close'){
    const meta=stack.pop();if(meta){t.type='folio_callout_close';t.meta=meta;}
   }
  }
 });
 md.renderer.rules.folio_callout_open=(tokens,i)=>{
  const {kind,fold,title}=tokens[i].meta;
  const label=md.utils.escapeHtml(title);
  return fold?`<details class="callout" data-kind="${kind}"${fold==='+'?' open':''}><summary class="callout-title">${label}</summary><div class="callout-body">`:`<aside class="callout" data-kind="${kind}"><div class="callout-title">${label}</div><div class="callout-body">`;
 };
 md.renderer.rules.folio_callout_close=(tokens,i)=>tokens[i].meta.fold?'</div></details>':'</div></aside>';

 md.core.ruler.push('folio-headings', state=>{
  for(let i=0;i<state.tokens.length;i++) {
   const t=state.tokens[i];
   if(t.type==='heading_open') {
    const inline=state.tokens[i+1];
    const text=(inline.children||[]).map(c=>c.type==='text'||c.type==='code_inline'?c.content:c.type==='image'?c.content:'').join('')||inline.content;
    const slug=text.toLowerCase().replace(/[^\p{L}\p{N} _-]/gu,'').trim().replace(/\s+/g,'-')||'section';
    let id=slug,n=1; while(used.has(id)) id=slug+'-'+n++; used.add(id);
    t.attrSet('id',id); headings.push({id,title:text,level:Number(t.tag.slice(1))});
   }
  }
 });
 md.renderer.rules.image=(tokens,idx)=>{
  const t=tokens[idx], ref=t.attrGet('src')||'', id=images.length;
  images.push({id,reference:ref});
  const alt=md.utils.escapeHtml(t.content||'Image');
  return `<figure class="image-frame"><img loading="lazy" data-image="${id}" src="${assetPrefix}${encodeURIComponent(ref)}" alt="${alt}"><figcaption class="image-fallback" hidden>Image unavailable · ${alt}. Use “Allow image folder…” for local images.</figcaption></figure>`;
 };
 for(const rule of ['fence','code_block']) md.renderer.rules[rule]=(tokens,idx)=>{
  const t=tokens[idx],id=codeBlocks.length; codeBlocks.push(t.content);
  const language=rule==='fence'?(t.info||'').trim().split(/\s+/)[0]:'';
  let preview='',fallback='';
  if(language==='mermaid'){
   const diagram=diagrams.length;diagrams.push(t.content);
   preview=`<div class="diagram-preview" data-diagram="${diagram}" role="img" aria-label="Mermaid diagram"><span class="render-status">Rendering diagram…</span></div>`;
  }else if(['math','latex'].includes(language)){
   try{preview=`<div class="math-preview">${mathEngine.renderToString(t.content,{displayMode:true})}</div>`;}
   catch{preview='<p class="render-status">Equation could not be rendered. Original source is below.</p>';}
  }
  let rendered=md.utils.escapeHtml(t.content);
  if(!preview&&t.content.length<=100000&&hljs.getLanguage(language)){
   try{rendered=hljs.highlight(t.content,{language,ignoreIllegals:true}).value;}catch{}
  }
  return `${preview}<section class="code-block"><button class="code-copy" type="button" data-copy="${id}" aria-label="Copy code block">Copy</button><details class="source-details" open><summary><span>${md.utils.escapeHtml(language||'Text')}${fallback}</span></summary><pre tabindex="0" aria-label="Code"><code>${rendered}</code></pre></details></section>`;
 };
 const originalTableOpen=md.renderer.rules.table_open;
 md.renderer.rules.table_open=(tokens,idx,options,env,self)=>'<div class="table-scroll" tabindex="0" role="region" aria-label="Scrollable table">'+(originalTableOpen?originalTableOpen(tokens,idx,options,env,self):self.renderToken(tokens,idx,options));
 md.renderer.rules.table_close=()=>'</table></div>';
 const metadataHTML=metadata?`<details class="metadata"><summary>Document properties</summary><pre><code>${md.utils.escapeHtml(metadata[1])}</code></pre></details>`:'';
 const env={}, tokens=md.parse(markdown,env);
 if(editing){
  const offsets=[0];for(const match of markdown.matchAll(/\r\n|\n|\r/g))offsets.push(match.index+match[0].length);
  const base=metadata?.[0].length||0;
  const allowed=new Set(['paragraph_open','paragraph_close','heading_open','heading_close','bullet_list_open','bullet_list_close','ordered_list_open','ordered_list_close','list_item_open','list_item_close','blockquote_open','blockquote_close','inline']);
  const inlineAllowed=new Set(['text','softbreak','hardbreak','strong_open','strong_close','em_open','em_close','s_open','s_close','code_inline','link_open','link_close']);
  for(let i=0;i<tokens.length;i++){
   const t=tokens[i];if(t.level!==0||!t.map||!['paragraph_open','heading_open','bullet_list_open','ordered_list_open','blockquote_open'].includes(t.type))continue;
   let end=i+1,depth=t.nesting;while(end<tokens.length&&depth){depth+=tokens[end].nesting;end++;}
   const group=tokens.slice(i,end),start=base+offsets[t.map[0]],finish=base+(offsets[t.map[1]]??markdown.length);
   const raw=originalSource.slice(start,finish);
   if(group.some(x=>!allowed.has(x.type)||(x.children||[]).some(c=>!inlineAllowed.has(c.type)))||/%%|\[\[|\[\^|\]\s*\[|\$|\\\(/.test(raw))continue;
   // Reference links carry definitions outside this block; leave them intact in Source.
   if((env.references&&Object.keys(env.references).length)&&group.some(x=>(x.children||[]).some(c=>c.type==='link_open')))continue;
   const id=String(blocks.length);blocks.push({id,start,end:finish});
   t.attrSet('data-edit',id);t.attrSet('contenteditable','true');t.attrSet('spellcheck','true');
  }
 }
 return {html:metadataHTML+md.renderer.render(tokens,md.options,env),headings,images,codeBlocks,diagrams,blocks};
}
