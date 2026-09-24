// Conservative source adapters: an unsupported shape stays in Source mode.
const ending = raw => raw.includes('\r\n') ? '\r\n' : '\n';
const trailing = raw => raw.match(/(?:\r\n|\n|\r)$/)?.[0] || '';

export function safeLinkDestination(value) {
 const url = value.trim();
 if (!url || /[\u0000-\u0020\u007f<>"'\\]/.test(url) || url.startsWith('//')) return null;
 if (/^[a-z][a-z\d+.-]*:/i.test(url) && !/^(https?:|mailto:)/i.test(url)) return null;
 if (/^https?:/i.test(url)) {try {if (!new URL(url).hostname) return null;} catch {return null;}}
 if (/^mailto:/i.test(url) && !/^mailto:[^@\s]+@[^@\s]+$/i.test(url)) return null;
 return url;
}

export function safeImagePath(value) {
 const path = value.trim();
 let decoded;
 try {decoded=decodeURIComponent(path);} catch {return null;}
 if (!decoded || /[\u0000-\u001f\u007f<>"'\\]/.test(decoded) || decoded.startsWith('/') || decoded.startsWith('//') || /^[a-z][a-z\d+.-]*:/i.test(decoded) || decoded.split('/').includes('..') || !/\.(png|jpe?g|gif|webp|heic|tiff?|bmp)$/i.test(decoded)) return null;
 return path;
}

export function parseCodeSource(raw) {
 const lines = raw.split(/\r\n|\n|\r/);
 const header = lines[0]?.match(/^(`{3,}|~{3,})([a-z\d_+#.-]*)$/i);
 if (!header || lines.length < 2) return null;
 const final = trailing(raw) ? lines.at(-2) : lines.at(-1);
 if (!final || final[0] !== header[1][0] || final.length < header[1].length || !new RegExp('^' + (header[1][0] === '`' ? '`' : '~') + '+$').test(final)) return null;
 return {kind:'code', marker:header[1], language:header[2], text:lines.slice(1, trailing(raw) ? -2 : -1).join('\n'), newline:ending(raw), suffix:trailing(raw)};
}

export function formatCodeSource(previous, language, text) {
 if (!/^[a-z\d_+#.-]{0,40}$/i.test(language) || /\r/.test(text) || text.length > 1_000_000) return null;
 const char = previous.marker[0];let longest = 0;
 for (const match of text.matchAll(new RegExp(char === '`' ? '`+' : '~+', 'g'))) longest=Math.max(longest,match[0].length);
 if (longest > 128) return null;
 const marker = char.repeat(Math.max(previous.marker.length, longest + 1, 3));
 const nl = previous.newline;
 return marker + language + nl + text.replace(/\n/g,nl) + nl + marker + previous.suffix;
}

function escapedPipe(value,index) {
 let slashes=0;for(let i=index-1;i>=0&&value[i]==='\\';i--)slashes++;
 return slashes%2===1;
}
function cells(line) {
 if (/`/.test(line)) return null; // Code spans can contain literal pipes.
 let value = line.trim();
 if(value.startsWith('|'))value=value.slice(1);
 if(value.endsWith('|')&&!escapedPipe(value,value.length-1))value=value.slice(0,-1);
 const parts=[],current=[];
 for(let i=0;i<value.length;i++){
  if(value[i]==='|'&&!escapedPipe(value,i)){parts.push(current.join('').trim());current.length=0;}
  else current.push(value[i]);
 }
 parts.push(current.join('').trim());
 return parts;
}
export function parseTableSource(raw) {
 const lines = raw.trimEnd().split(/\r\n|\n|\r/);
 if (lines.length < 2) return null;
 const header = cells(lines[0]), rule = cells(lines[1]);
 if (!header || !rule || header.length !== rule.length || header.length > 30 || lines.length > 201 || !rule.every(cell => /^:?-{3,}:?$/.test(cell))) return null;
 const rows = [header];
 for (const line of lines.slice(2)) {
  const row = cells(line); if (!row || row.length !== header.length) return null;
  rows.push(row);
 }
 return {kind:'table', rows, alignment:rule.map(cell => ({left:cell.startsWith(':'),right:cell.endsWith(':')})), newline:ending(raw), suffix:trailing(raw)};
}
export function formatTableSource(previous, rows) {
 if (!Array.isArray(rows) || !rows.length || !rows[0]?.length || rows.length > 200 || rows[0].length > 30 || !rows.every(row => row.length === rows[0].length)) return null;
 const cols = rows[0].length;
 const encode = cell => {
  const value=String(cell).replace(/\r|\n/g,' ');let result='';
  for(let i=0;i<value.length;i++)result+=value[i]==='|'&&!escapedPipe(value,i)?'\\|':value[i];
  return result;
 };
 const rule = Array.from({length:cols}, (_,i) => {
  const alignment = previous.alignment[i] || {left:false,right:false};
  return (alignment.left?':':'') + '---' + (alignment.right?':':'');
 });
 const line = row => '| ' + row.map(encode).join(' | ') + ' |';
 return [line(rows[0]),line(rule),...rows.slice(1).map(line)].join(previous.newline) + previous.suffix;
}

export function parseImageSource(raw) {
 const line = raw.trimEnd();
 const match = line.match(/^!\[([^\]\r\n]*)\]\((<[^>\r\n]+>|[^()\s\r\n]+)\)$/);
 if (!match) return null;
 const path = match[2].startsWith('<') ? match[2].slice(1,-1) : match[2];
 if (!safeImagePath(path)) return null;
 return {kind:'image', alt:match[1], path, newline:ending(raw), suffix:trailing(raw)};
}
export function formatImageSource(previous, alt, path) {
 const safe = safeImagePath(path);
 if (!safe || /[\r\n\]]/.test(alt) || /\r|\n/.test(path)) return null;
 return '![' + alt + '](<' + safe.replace(/ /g,'%20') + '>)' + previous.suffix;
}
