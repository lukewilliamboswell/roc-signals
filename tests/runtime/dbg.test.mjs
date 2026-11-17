import test from 'node:test';
import assert from 'node:assert/strict';
import {readDbg,RocEngineRuntime} from '../../platform/runtime.mjs';
const word = value => [value&255,value>>>8&255,value>>>16&255,value>>>24];
function fixture(entries,dropped=0) {
  const memory=new WebAssembly.Memory({initial:1});
  const bytes=[...word(dropped)];
  for(const {text,full} of entries) {
    const value=[...new TextEncoder().encode(text)];
    bytes.push(...word(full??value.length),...word(value.length),...value);
  }
  new Uint8Array(memory.buffer).set(bytes);
  return {memory,dbg_len:()=>entries.length?bytes.length:0,dbg_ptr:()=>0};
}
function runtime(x,mode='console') {
  return Object.assign(Object.create(RocEngineRuntime.prototype),{x,dbg:mode,dbgPrinting:true,dbgTold:false});
}
test('independent debug frames retain order full lengths BOM and Unicode',()=> {
  assert.deepEqual(readDbg(fixture([{text:'\uFEFFfirst'},{text:'😀',full:1025}],7)),{dropped:7,entries:[{text:'\uFEFFfirst',bytes:8},{text:'😀',bytes:1025}]});
  assert.equal(readDbg(fixture([])),null);
});
test('malformed lengths and invalid UTF8 cannot become debug text',()=> {
  const x=fixture([{text:'x'}]);
  const view=new DataView(x.memory.buffer);
  view.setUint32(8,1025,true); assert.throws(()=>readDbg(x));
  view.setUint32(8,1,true);new Uint8Array(x.memory.buffer)[12]=255;
  assert.throws(()=>readDbg(x));
  assert.throws(()=>readDbg({...x,dbg_len:()=>4101}));
});
test('printing failure disables printing but later faults still receive text',()=> {
  const x=fixture([{text:'before fault'}]),rt=runtime(x);
  const log=console.log,error=console.error;let errors=0;
  try {
    console.log=()=>{throw Error('wrapped console');};console.error=()=>{errors++;};
    assert.deepEqual(rt.takeDbg(null),readDbg(x));
    assert.equal(rt.dbgPrinting,false);
    assert.deepEqual(rt.takeDbg(null),readDbg(x));assert.equal(errors,1);
  } finally {console.log=log;console.error=error;}
});
test('off never reads value bytes and explains itself once without values',()=> {
  let reads=0,infos=[];const info=console.info;
  const rt=runtime({dbg_len:()=>1,dbg_ptr:()=>{reads++;throw Error('text read');}},'off');
  try {console.info=line=>infos.push(line);assert.equal(rt.takeDbg(null),null);rt.takeDbg(null);rt.takeDbg('task',true);}
  finally {console.info=info;}
  assert.equal(reads,0);assert.equal(infos.length,1);assert.match(infos[0],/dbg: "off"/);
});
test('the first job alone explains off output without reading values',()=> {
  const info=console.info;const infos=[];
  const rt=runtime({dbg_ptr:()=>{throw Error('job text read');}},'off');
  try {
    console.info=line=>infos.push(line);
    assert.equal(rt.takeDbg('only-task',true),null);
    assert.equal(rt.takeDbg('only-task',true),null);
  } finally {console.info=info;}
  assert.equal(infos.length,1);assert.match(infos[0],/dbg: "off"/);
});
test('call boundary is cleared before executor work and none makes no extra Wasm reads',()=> {
  let calls=0,reads=0;
  const rt=runtime({event:()=>{calls++;return 0;},dbg_len:()=>{reads++;return 0;}});
  rt.callEvent(1,2);assert.equal(calls,1);assert.equal(reads,0);assert.equal(rt.calling,false);
  rt.x.event=()=>{throw Error('raw trap');};assert.throws(()=>rt.callEvent(1,2));assert.equal(rt.calling,true);
});

test('job observations reject oversized records without changing delivery',()=> {
  const rt=runtime({});const error=console.error;
  try {
    console.error=()=>{};
    assert.equal(rt.takeDbg('task',{dropped:0,entries:Array.from({length:1025},()=>({text:'',bytes:0}))}),null);
    assert.equal(rt.dbgPrinting,false);
    const good={dropped:0,entries:[{text:'later valid fault',bytes:17}]};
    assert.deepEqual(rt.takeDbg('task',good),good);
  } finally {console.error=error;}
});

test('actual worker aggregates preparation text and retains it on task staging refusal',async()=> {
  const {PROTOCOL_VERSION}=await import('../../platform/runtime.mjs');
  const originalInstantiate=WebAssembly.instantiate,originalSelf=globalThis.self;
  const memory=new WebAssembly.Memory({initial:2});let length=0,debugLength=0,stagingRefusal=false,pointerReads=0;
  const put=text=>{const data=[...new TextEncoder().encode(text)];const encoded=[...word(0),...word(data.length),...word(data.length),...data];new Uint8Array(memory.buffer).set(encoded,8192);debugLength=encoded.length;};
  const x={memory,protocol_version:()=>PROTOCOL_VERSION,metric:index=>index===8?1n:0n,
    forget(){debugLength=0;},payload_reserve:()=>4096,files_stage:n=>stagingRefusal&&n?0:n,files_tokens:()=>128,files_released:()=>0,keys_released:()=>0,
    prepare(){put('prepared observation');},work(){this.ask();},ask(){put('task observation');new Uint8Array(memory.buffer).fill(0,0,4);length=4;},
    cmd_ptr:()=>0,cmd_len:()=>length,dbg_len:()=>debugLength,dbg_ptr(){pointerReads++;return 8192;},fault:()=>0};
  const messages=[];globalThis.self={postMessage:message=>messages.push(message)};
  WebAssembly.instantiate=async()=>({exports:x});
  try {
    // A genuine empty module supplies import metadata; only its exports are fake.
    // This exercises worker.mjs itself, not a second debug aggregation model.
    const module=new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0]));
    await import(`../../platform/worker.mjs?dbg-unit=${Date.now()}`);
    await self.onmessage({data:{type:'init',module,version:PROTOCOL_VERSION,dbg:true}});
    const job={type:'job',mode:'prepare',prepare:new Uint8Array(),payload:new Uint8Array(),prepareObjects:[],objects:[],maxOutputBytes:0};
    await self.onmessage({data:job});
    let result=messages.findLast(message=>message.type==='done');
    assert.deepEqual(result.dbg.entries.map(entry=>entry.text),['prepared observation','task observation']);
    stagingRefusal=true;
    await self.onmessage({data:{...job,objects:[{}]}});
    result=messages.findLast(message=>message.type==='fault');
    assert.equal(result.code,2);assert.deepEqual(result.dbg.entries.map(entry=>entry.text),['prepared observation']);
    stagingRefusal=false;
    await self.onmessage({data:{type:'init',module,version:PROTOCOL_VERSION,dbg:false}});
    const before=pointerReads;await self.onmessage({data:job});
    result=messages.findLast(message=>message.type==='done');
    assert.equal(result.dbg,true);assert.equal(pointerReads,before);
  } finally {WebAssembly.instantiate=originalInstantiate;globalThis.self=originalSelf;}
});
