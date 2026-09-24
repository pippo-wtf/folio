import mermaid from 'mermaid';
mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,
 maxTextSize:20000,maxEdges:200,htmlLabels:false,theme:'neutral',fontFamily:'Helvetica Neue, sans-serif',
 secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','htmlLabels','suppressErrorRendering'],
 flowchart:{htmlLabels:false}, deterministicIds:true});
let serial=0;
export async function renderDiagrams(sources,isCurrent){
 for(let i=0;i<sources.length;i++){
  if(!isCurrent())return;
  const target=document.querySelector(`[data-diagram="${i}"]`);if(!target)continue;
  const source=sources[i];
  if(i>=12||source.length>20000||/%%\{|^\s*---/m.test(source)){
   target.removeAttribute('role');target.textContent='Diagram exceeds the preview limits or contains configuration. Original source is below.';continue;
  }
  const host=document.createElement('div');host.className='diagram-staging';document.body.append(host);
  try{
   const {svg}=await mermaid.render(`folio-diagram-${++serial}`,source,host);
   if(!isCurrent())return;
   // Mermaid strict mode sanitizes SVG; also remove external resource and link surfaces.
   const doc=new DOMParser().parseFromString(svg,'image/svg+xml');
   doc.querySelectorAll('script,foreignObject,image,a').forEach(el=>el.remove());
   doc.querySelectorAll('*').forEach(el=>{for(const a of [...el.attributes]){
    if(/^on/i.test(a.name)||/^(href|xlink:href)$/i.test(a.name))el.removeAttribute(a.name);
   }});
   target.replaceChildren(document.importNode(doc.documentElement,true));
  }catch{if(isCurrent()){target.removeAttribute('role');target.textContent='Diagram could not be rendered. Original source is below.';}}
  finally{host.remove();}
 }
}
