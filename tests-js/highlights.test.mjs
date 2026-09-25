import test from 'node:test';
import assert from 'node:assert/strict';
import {anchor,locate,overlaps,unionSelection} from '../web/highlight-anchors.js';
test('anchors restore unicode text and follow an insertion before a passage',()=>{
 const text='😀 Intro. Words worth keeping. End.';
 const start=text.indexOf('Words'),record=anchor(text,start,start+19,'id');
 assert.equal(record.quote,'Words worth keeping');
 assert.deepEqual(locate(text,record),{start,end:start+19});
 const changed='New opening. '+text;
 assert.deepEqual(locate(changed,record),{start:start+13,end:start+32});
});
test('repeated quotes require unambiguous context, deleted text stays unlocated',()=>{
 const text='First keep this. Second keep this.';
 const start=text.lastIndexOf('keep this'),record=anchor(text,start,start+9,'id');
 assert.equal(locate(text,record).start,start);
 assert.equal(locate('nothing remains',record),null);
 assert.equal(locate('repeat repeat',{start:0,quote:'repeat',prefix:'',suffix:''}),null);
});
test('selection bounds and overlapping marks',()=>{
 assert.equal(anchor('word',0,0,'id'),null);
 assert.equal(anchor('word',-1,3,'id'),null);
 assert.equal(anchor(' '.repeat(10),0,10,'id'),null);
 assert.equal(anchor('a'.repeat(20001),0,20001,'id'),null);
 assert.equal(overlaps({start:0,end:3},{start:3,end:6}),false);
 assert.equal(overlaps({start:0,end:4},{start:3,end:6}),true);
});

test('overlapping selections preserve the whole existing mark',()=>{
 assert.deepEqual(unionSelection({start:5,end:12},[{start:11,end:20},{start:0,end:8},{start:30,end:40}]),{start:0,end:20});
});

test('comment targets reuse exact highlights without absorbing neighboring feedback',async()=>{
 const {commentTarget}=await import('../web/highlight-anchors.js');
 assert.equal(typeof commentTarget,'function');
 const text='First passage. Second passage.';
 const first={...anchor(text,0,14,'first'),comment:'Keep this'};
 const second=anchor(text,15,text.length,'second');
 assert.equal(commentTarget(text,[first,second],{start:0,end:14},'new').id,'first');
 assert.equal(commentTarget(text,[first,second],{ids:['second']},'new').id,'second');
 const fresh=commentTarget(text,[first,second],{start:6,end:22},'new');
 assert.equal(fresh.quote,text.slice(6,22));assert.equal(fresh.id,'new');
 assert.equal(first.comment,'Keep this');
 assert.equal(commentTarget(text,[first],{ids:['missing']},'new'),null);
});
