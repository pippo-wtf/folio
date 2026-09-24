// Offsets use JavaScript UTF-16 units; quotes and context survive nearby edits.
export function anchor(text,start,end,id) {
 if(!Number.isInteger(start)||!Number.isInteger(end)||start<0||end<=start||end>text.length||end-start>20000) return null;
 const quote=text.slice(start,end);if(!quote.trim())return null;
 return {id,start,quote,prefix:text.slice(Math.max(0,start-64),start),suffix:text.slice(end,end+64)};
}
export function locate(text,record) {
 if(!record || typeof record.quote!=='string' || !record.quote.length) return null;
 const {quote,prefix='',suffix=''}=record;
 const matches=[];let at=text.indexOf(quote);
 while(at!==-1){matches.push(at);if(matches.length>10000)return null;at=text.indexOf(quote,at+1);}
 const contextual=matches.filter(start=>text.slice(Math.max(0,start-prefix.length),start)===prefix&&text.slice(start+quote.length,start+quote.length+suffix.length)===suffix);
 // Even an old offset is unsafe when repeated text became ambiguous.
 const start=contextual.length===1?contextual[0]:(matches.length===1?matches[0]:null);
 return start===null?null:{start,end:start+quote.length};
}
export const overlaps=(a,b)=>a.start<b.end&&b.start<a.end;
export function unionSelection(selection,ranges){
 const result={start:selection.start,end:selection.end};let changed;
 do{changed=false;for(const range of ranges){if(overlaps(result,range)){const a=Math.min(result.start,range.start),b=Math.max(result.end,range.end);if(a!==result.start||b!==result.end){result.start=a;result.end=b;changed=true;}}}}while(changed);
 return result;
}
