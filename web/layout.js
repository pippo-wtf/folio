const fonts = ['Source Serif 4','Oswald','Helvetica Neue','Avenir Next','Palatino','Georgia','Menlo','Monaco','Courier'];
const font = v => fonts.includes(v) ? `"${v}"` : '"Helvetica Neue"';
const color = (v,f) => /^#[0-9a-f]{6}$/i.test(v || '') ? v : f;
const num = (v,min,max,f) => typeof v==='number' && Number.isFinite(v) ? Math.max(min,Math.min(max,v)) : f;
export function layoutCSS(s={}) {
 const n=(key,min,max,f)=>num(s[key],min,max,f);
 const gap=n('blockGap',.5,4,2.1), scale=n('headingScale',.75,1.5,1);
 const weight=(key,family,fallback)=>n(key,family==='Oswald'||family==='Source Serif 4'?200:100,family==='Oswald'?700:900,fallback);
 const bodyWeight=weight('bodyWeight',s.bodyFont,400);
 const rule=s.calloutStyle==='plain'?0:n('ruleWidth',0,6,3);
 return `
 :root { --paper:${color(s.lightPaper,'#FFFFFF')};--ink:${color(s.lightInk,'#191919')};--accent:${color(s.accent,'#2CFF05')}; }
 @media(prefers-color-scheme:dark){:root:not([data-appearance="light"]){--paper:${color(s.darkPaper,'#171717')};--ink:${color(s.darkInk,'#E9E9E9')};}}
 :root[data-appearance="dark"]{--paper:${color(s.darkPaper,'#171717')};--ink:${color(s.darkInk,'#E9E9E9')};}
 body{font-family:${font(s.bodyFont)},serif;font-optical-sizing:auto;font-weight:${bodyWeight};line-height:${n('lineHeight',1.2,2,1.55)};}
 main{padding-top:${n('topInset',16,160,82)}px;padding-bottom:${n('bottomInset',24,200,132)}px;max-width:calc(${n('columnWidth',38,90,60)}ch + min(${n('pageInset',16,100,48)}px,12vw) * 2);padding-left:min(${n('pageInset',16,100,48)}px,12vw);padding-right:min(${n('pageInset',16,100,48)}px,12vw);}
 h1,h2,h3,h4,h5,h6{font-family:${font(s.headingFont)},sans-serif;font-weight:${weight('headingWeight',s.headingFont,700)};${s.headingFont==='Oswald'?'letter-spacing:0;':''}}
 strong,b{font-weight:${Math.min(s.bodyFont==='Oswald'?700:900,Math.max(700,bodyWeight+200))};}
 h1{font-size:${1.65*scale}rem;}h2{font-size:${1.3*scale}rem;}h3{font-size:${1.1*scale}rem;}h4,h5,h6{font-size:${1*scale}rem;}
 h2,h3,h4,h5,h6{margin-top:${n('headingGap',.8,3.5,2.1)}rem;}
 p,ul,ol{margin-bottom:${n('paragraphGap',.5,3,1.6)}em;}li{margin-top:${n('listGap',.1,1.2,.5)}em;margin-bottom:${n('listGap',.1,1.2,.5)}em;}
 li>ul,li>ol{margin-top:.4em;margin-bottom:.4em;}
 blockquote,.callout,.code-block,.table-scroll,figure{margin-top:${gap}em;margin-bottom:${gap}em;}
 code,pre,.metadata pre{font-family:${font(s.codeFont)},monospace;}.code-block pre,.code-block pre code{font-size:${n('codeSize',12,26,18)/n('bodySize',16,36,24)}rem;}
 .code-block,.table-scroll,.image-fallback{border-radius:${n('radius',0,16,2)}px;}
 .callout{border-left-width:${rule}px;${s.calloutStyle==='box'?'background:var(--soft);padding:1em;border-radius:'+n('radius',0,16,2)+'px;':'background:none;border-radius:0;padding:0 0 0 '+(rule?'1em':'0')+';'}}
 #reading-scroll-indicator{width:${n('scrollbarWidth',1,8,3)}px;}
 `;
}
export function applyLayout(settings,zoom=1) {
 let style=document.getElementById('folio-layout');
 if(!style){style=document.createElement('style');style.id='folio-layout';document.head.appendChild(style);}
 style.textContent=layoutCSS(settings);
 document.documentElement.style.fontSize=(num(settings?.bodySize,16,36,24)*num(zoom,.7,2.5,1))+'px';
}
