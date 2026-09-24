// Small, explicit Obsidian-compatible additions. Code tokens are left untouched.
export function writingExtensions(md) {
 md.inline.ruler.before('text','folio-comment',(state,silent)=>{
  if(state.src.slice(state.pos,state.pos+2)!=='%%')return false;
  const end=state.src.indexOf('%%',state.pos+2);if(end<0)return false;
  state.pos=end+2;return true;
 });
 md.block.ruler.before('paragraph','folio-comment-block',(state,start,end,silent)=>{
  const pos=state.bMarks[start]+state.tShift[start];
  if(state.src.slice(pos,pos+2)!=='%%')return false;
  const close=state.src.indexOf('%%',pos+2);if(close<0)return false;
  let next=start;while(next<end&&state.eMarks[next]<close+2)next++;
  if(next>=end||state.src.slice(close+2,state.eMarks[next]).trim())return false;
  if(!silent)state.line=next+1;return true;
 });
 md.inline.ruler.before('link','folio-wiki',(state,silent)=>{
  const source=state.src.slice(state.pos),match=source.match(/^(!?)\[\[([^\]\n]+)\]\]/);
  if(!match)return false;
  if(!silent){
   const [target,...aliases]=match[2].split('|'),label=aliases.join('|')||target;
   const image=match[1]&&/\.(png|jpe?g|gif|webp|heic|tiff?|bmp)$/i.test(target);
   if(image){const t=state.push('image','img',0);t.attrSet('src',target);t.content=label;t.children=[];}
   else {const t=state.push('folio_wiki','',0);t.meta={target,label,embed:!!match[1]};}
  }
  state.pos+=match[0].length;return true;
 });
 md.renderer.rules.folio_wiki=(tokens,i)=>{
  const {target,label,embed}=tokens[i].meta,e=md.utils.escapeHtml;
  return `<a class="wiki-link" href="${target.startsWith('#')?e(target):'#'}" data-note="${e(target)}">${embed?'Embedded note: ':''}${e(label)}</a>${embed?'<span class="embed-hint"> · open separately</span>':''}`;
 };
}
