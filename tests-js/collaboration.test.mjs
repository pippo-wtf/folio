import test from 'node:test';
import assert from 'node:assert/strict';
import {locateSharedAnchor} from '../web/shared-review.js';
const record=(quote,start=0,prefix='',suffix='')=>({id:'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',start,quote,prefix,suffix,rawSourceRevision:'a'.repeat(64),decodedSourceRevision:'b'.repeat(64)});
test('shared UTF-16 anchors relocate after insertion and preserve every identity',()=>{
 const text='😀 Intro. Words worth keeping. End.';
 const a=record('Words worth keeping',text.indexOf('Words'),'😀 Intro. ','. End.');
 const b={...a,id:'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',authorName:'Also Alex'};
 assert.deepEqual(locateSharedAnchor('New opening. '+text,a),{status:'located',start:23,end:42});
 assert.deepEqual(locateSharedAnchor(text,a),locateSharedAnchor(text,b));
 assert.notEqual(a.id,b.id);
});
test('shared missing and ambiguous passages fail closed despite original offset',()=>{
 assert.deepEqual(locateSharedAnchor('repeat repeat',record('repeat')),{status:'ambiguous'});
 assert.deepEqual(locateSharedAnchor('gone',record('repeat')),{status:'missing'});
 assert.deepEqual(locateSharedAnchor('First repeat. Second repeat.',record('repeat',21,'Second ','.')),{status:'located',start:21,end:27});
});
test('shared records require rendered offset, bounded context and explicit source revisions',()=>{
 for(const patch of [{start:-1},{start:undefined,sourceOffsetUTF16:0},{quote:''},{quote:'a'.repeat(20001)},{prefix:'a'.repeat(65)},{suffix:null},{rawSourceRevision:''},{decodedSourceRevision:undefined},{id:'not-a-UUID'}]){
  assert.deepEqual(locateSharedAnchor('repeat',{...record('repeat'),...patch}),{status:'invalid'});
 }
});

test('shared batch matching rejects case variants of one UUID before registry admission',async()=>{
 const module=await import('../web/shared-review.js');
 assert.equal(typeof module.locateSharedRecords,'function');
 const a=record('Original'),b={...record('second',10),id:a.id.toLowerCase()};
 assert.deepEqual(module.locateSharedRecords('Original. second.',[a,b]),[{id:a.id,status:'invalid'},{id:b.id,status:'invalid'}]);
 const distinct={...b,id:'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'};
 assert.deepEqual(module.locateSharedRecords('Original. second.',[a,distinct]),[{id:a.id,status:'located',start:0,end:8},{id:distinct.id,status:'located',start:10,end:16}]);
});
