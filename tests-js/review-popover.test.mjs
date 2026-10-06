import test from 'node:test';
import assert from 'node:assert/strict';
test('popover stays inside small viewport and flips above a low anchor',async()=>{
 const module=await import('../web/review-popover.js').catch(()=>({}));
 assert.equal(typeof module.popoverPosition,'function');
 assert.deepEqual(module.popoverPosition({left:780,bottom:690,top:670},340,250,800,700),{left:452,top:412});
 assert.deepEqual(module.popoverPosition({left:-30,bottom:10,top:0},400,300,200,180),{left:8,top:8});
});
