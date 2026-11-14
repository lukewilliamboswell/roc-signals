// Actual page/worker behavior plus independent raw host edge contracts.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {launch} from './cdp.mjs';
import {parseArgs,runtimeFiles} from './args.mjs';
import {protocolFixtureSection} from './protocol-fixture.mjs';
const options=parseArgs(process.argv.slice(2),["scope","job-only-wasm"],["runtime"]);
const scope=options.scope??"all";
if(!["all","raw"].includes(scope)||scope==="all"&&!options.wasm) throw Error("use --wasm APP.wasm, or --scope raw for only independent raw contracts");
const files={...runtimeFiles(options.runtime),'app.wasm':options.wasm,...(options['job-only-wasm']?{'job-only.wasm':options['job-only-wasm']}:{})};
const server=http.createServer((request,response)=>{
  const file=files[path.basename(new URL(request.url,'http://x').pathname)];
  response.writeHead(200,{'content-type':file?(file.endsWith('.wasm')?'application/wasm':'text/javascript'):'text/html'});
  response.end(file?fs.readFileSync(file):'<!doctype html><body></body>');
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await launch({executablePath:options.chrome});
let count=0;
const check=(name,condition)=>{assert.ok(condition,name);count++;console.log(`ok ${name}`);};
async function open(mode='worker',dbg='console',wasm='app.wasm') {
  const page=await browser.newPage();await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.evaluate(async ({mode,dbg,wasm})=>{
    window.__lines=[];window.__faults=[];window.__workerFaults=[];
    for(const key of ['log','error','info']) {const original=console[key].bind(console);console[key]=(...parts)=>{window.__lines.push([key,parts.join(' ')]);original(...parts);};}
    const {mountRocEngineApp}=await import('/runtime.mjs');
    const root=document.createElement('div');document.body.append(root);window.__root=root;
    window.__rt=await mountRocEngineApp({wasmUrl:`/${wasm}`,root,workers:mode,dbg,manualEffects:true,onFault:f=>window.__faults.push(f),onWorkerFault:f=>window.__workerFaults.push(f)});
    window.__click=label=>[...root.querySelectorAll('button')].find(button=>button.textContent===label).click();
  },{mode,dbg,wasm});
  return page;
}
try {
  if(scope!=="raw") {
  for(const mode of ['worker','inline']) {
    const page=await open(mode);
    await page.evaluate(async()=>{await __rt.runEffect(__rt.pendingEffects()[0].id);});
    await page.evaluate(async()=>{__click('Increment');await __rt.runEffect(__rt.pendingEffects()[0].id);});
    const report=await page.evaluate(()=>({lines:__lines.map(row=>row[1]),count:__root.querySelector('[data-testid=count]').textContent,answer:__root.querySelector('[data-testid=answer]').textContent,fault:__rt.poisoned}));
    check(`${mode}: handler and reader observations preserve the real answer`,report.count==='1'&&report.answer==='kept:1'&&!report.fault);
    const first=report.lines.findIndex(line=>line.includes('handler-first')),second=report.lines.findIndex(line=>line.includes('handler-second'));
    check(`${mode}: two handler entries retain order`,first>=0&&second===first+1);
    check(`${mode}: actual preparation and job output reach page console`,report.lines.some(line=>line.startsWith('[dbg task "dbg/echo"]')&&line.includes('at: "prepare"'))&&report.lines.filter(line=>line.startsWith('[dbg task "dbg/echo"]')&&line.includes('at: "task"')).length===2);
    await page.evaluate(()=>__click('Many'));
    const many=await page.evaluate(()=>__lines.map(row=>row[1]));
    check(`${mode}: overflow retains newest entry and reports dropped entries`,many.some(line=>line.includes('earlier entries of this call were dropped'))&&many.some(line=>line.includes('index: 1999'))&&!many.some(line=>line.includes('index: 0 }')));
    await page.evaluate(()=>__click('Long'));
    check(`${mode}: long Unicode entry reports original bytes`,await page.evaluate(()=>__lines.some(row=>row[1].includes('… (')&&row[1].includes('bytes)'))));
    await page.evaluate(()=>__click('Crash'));
    const crash=await page.evaluate(()=>({fault:__rt.poisoned,lines:__lines.map(row=>row[1]),same:__faults[0]===__rt.poisoned,len:__rt.x.dbg_len()}));
    check(`${mode}: trap retains dbg independently of its diagnostic`,crash.fault.class==='app_crash'&&crash.fault.message==='boom after dbg'&&crash.fault.dbg.entries.some(entry=>entry.text.includes('before-crash'))&&crash.same&&crash.len>0);
    check(`${mode}: trapped text precedes fault line`,crash.lines.findIndex(line=>line.includes('before-crash'))<crash.lines.findIndex(line=>line.startsWith('roc engine fault')));
    await page.close();
  }
  {
    const page=await open();await page.evaluate(()=>__click('Recurse'));
    const fault=await page.evaluate(()=>__rt.poisoned);
    check('unclassified recursion trap retains its call text',fault.code===0&&fault.class==='executor'&&fault.dbg.entries.some(entry=>entry.text.includes('before-recursion')));
    await page.close();
  }
  {
    const page=await open();
    const result=await page.evaluate(async()=>{
      console.log=()=>{throw Error('wrapped page console');};
      __click('Increment');
      const applied=!__rt.poisoned&&__root.querySelector('[data-testid=count]').textContent==='1';
      __click('Increment');__click('Crash');
      const fault=__rt.poisoned;
      await __rt.recover();__click('Increment');
      return {applied,fault,errors:__lines.filter(row=>row[1].startsWith('roc dbg: printing failed')).length,recovered:!__rt.poisoned&&__root.querySelector('[data-testid=count]').textContent==='1',printing:__rt.dbgPrinting};
    });
    check('console throw leaves actual batches applied and later fault text intact',result.applied&&result.errors===1&&result.fault.dbg.entries.some(entry=>entry.text.includes('before-crash')));
    check('printing remains disabled after recover while real turns still apply',result.recovered&&!result.printing);
    await page.close();
  }
  {
    const page=await open('worker','off');
    await page.evaluate(async()=>{__click('Increment');await __rt.runEffect(__rt.pendingEffects().at(-1).id);__click('Crash');});
    const off=await page.evaluate(()=>({lines:__lines,fault:__rt.poisoned}));
    check('off prints no values, emits one explanation and removes fault text',off.lines.filter(row=>row[0]==='info'&&row[1].includes('dbg: "off"')).length===1&&!off.lines.some(row=>row[1].startsWith('[dbg'))&&off.fault.dbg===null);
    await page.close();
  }
  {
    const page=await open();
    await page.evaluate(async()=>{await __rt.runEffect(__rt.pendingEffects()[0].id);});
    await page.evaluate(async()=>{__click('Task crash');await __rt.runEffect(__rt.pendingEffects()[0].id);});
    const fault=await page.evaluate(()=>__workerFaults[0]);
    check('reported job fault carries its own debug text',fault?.class==='app_crash'&&fault.dbg.entries.some(entry=>entry.text.includes('at: "task"')));
    await page.close();
  }
  {
    const page=await open();
    await page.evaluate(async()=>{await __rt.runEffect(__rt.pendingEffects()[0].id);});
    // A warm idle worker is posted synchronously. Cancel in this same page
    // task: its done message cannot be handled until after this callback.
    await page.evaluate(()=>{__click('Finish');window.__finishing=__rt.runEffect(__rt.pendingEffects()[0].id);__click('Reset');});
    await page.waitForFunction(()=>__rt.monitor.snapshot().pool.busy===0);
    check('cancelled Finish job still prints its completed observations',await page.evaluate(()=>__lines.some(row=>row[1].startsWith('[dbg task "dbg/echo"]')&&row[1].includes('input: -1'))));
    await page.evaluate(()=>{__click('Stop');window.__stopping=__rt.runEffect(__rt.pendingEffects()[0].id);__click('Reset');});
    await page.waitForFunction(()=>__rt.monitor.snapshot().pool.busy===0);
    check('a stopped job sends no debug text',await page.evaluate(()=>!__lines.some(row=>row[1].includes('[dbg task "dbg/stop"]'))));
    await page.close();
  }
  }
  if(options['job-only-wasm']) {
    for(const mode of ['worker','inline']) {
      const page=await open(mode,'off','job-only.wasm');
      check(`${mode}: job-only mount has no debug notice before its first answer`,await page.evaluate(()=>__lines.length===0&&__rt.x.dbg_len()===0));
      await page.evaluate(async()=>{await __rt.runEffect(__rt.pendingEffects()[0].id);});
      const first=await page.evaluate(()=>({lines:__lines,answer:__root.querySelector('[data-testid=answer]').textContent,fault:__rt.poisoned}));
      check(`${mode}: first task alone explains off once without values`,first.answer==='job:0'&&!first.fault&&first.lines.length===1&&first.lines[0][0]==='info'&&first.lines[0][1].includes('dbg: "off"'));
      await page.evaluate(async()=>{__click('Increment');await __rt.runEffect(__rt.pendingEffects()[0].id);});
      check(`${mode}: later task answers stay silent after the off notice`,await page.evaluate(()=>__lines.length===1&&__root.querySelector('[data-testid=answer]').textContent==='job:1'&&!__rt.poisoned));
      await page.close();
    }
  }
  // Hand-written valid declarations enter through the real mount boundary;
  // only the host exports are fake, to force traps before/after exact calls.
  const page=await browser.newPage();await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const raw=await page.evaluate(async section=>{
    const {RocEngineRuntime,PROTOCOL_VERSION}=await import('/runtime.mjs');
    const word=n=>[n&255,n>>>8&255,n>>>16&255,n>>>24];
    const part=(tag,bytes)=>[tag,...word(bytes.length),...bytes];
    const declarations=new Uint8Array([...part(2,word(0)),...part(5,word(0)),...part(6,word(0)),...part(10,[110,1]),...part(11,word(0)),...section]);
    let logs=[],errors=0;console.log=line=>logs.push(line);console.error=()=>errors++;
    const make=(bootTrap=false)=>{
      const memory=new WebAssembly.Memory({initial:2});let length=0,debugLength=0,reads=0;
      const put=text=>{const bytes=[...new TextEncoder().encode(text)];const encoded=[...word(0),...word(bytes.length),...word(bytes.length),...bytes];new Uint8Array(memory.buffer).set(encoded,8192);debugLength=encoded.length;};
      const x={memory,protocol_version:()=>PROTOCOL_VERSION,boot_keys(){put('declarations');if(bootTrap)throw Error('keys trap');new Uint8Array(memory.buffer).set(declarations);length=declarations.length;},payload_reserve:()=>65536,cmd_ptr:()=>0,cmd_len:()=>length,init(){debugLength=0;length=0;return 0;},event(){debugLength=0;return 0;},event_files(){debugLength=0;return 0;},files_released:()=>0,work_len:()=>0,fault:()=>0,metric:()=>0n,drop(){},dbg_len(){reads++;return debugLength;},dbg_ptr:()=>8192};
      const root=document.createElement('div');document.body.append(root);
      const rt=new RocEngineRuntime(x,root,{manualEffects:true});return {x,rt,put,reads:()=>reads};
    };
    const checks=[];
    let faults=0;const broken=make(true);broken.rt.onFault=()=>faults++;let thrown=null;try{broken.rt.mount();}catch(error){thrown=error;}
    checks.push(['boot_keys trap prints its preceding output',logs.includes('[dbg] declarations')]);
    checks.push(['boot_keys trap is contained once with its dbg text',thrown===null&&faults===1&&broken.rt.poisoned?.class==='executor'&&broken.rt.poisoned.dbg?.entries?.[0]?.text==='declarations']);
    logs=[];const normal=make();normal.rt.mount();
    const before=normal.reads();normal.rt.callEvent(1,1);
    checks.push(['quiet event makes no added Wasm calls',normal.reads()===before]);
    normal.x.event=()=>{normal.x.memory.grow(1);normal.put('returned');return 1;};normal.rt.callEvent(1,1);
    normal.rt.guard(()=>{throw Error('after return');});
    checks.push(['fresh views after growth and post-return fault has null dbg',logs.includes('[dbg] returned')&&normal.rt.poisoned.dbg===null&&logs.filter(line=>line==='[dbg] returned').length===1]);
    const wrapped=make();wrapped.rt.mount();console.log=()=>{throw Error('console wrapped');};
    wrapped.x.event=()=>{wrapped.put('before successful batch');return 1;};wrapped.rt.callEvent(1,1);
    wrapped.x.event=()=>{wrapped.put('later trap');throw Error('raw trap');};wrapped.rt.guard(()=>wrapped.rt.callEvent(1,1));
    checks.push(['console failure preserves later fault dbg without poisoning successful call',wrapped.rt.poisoned.dbg.entries[0].text==='later trap'&&!wrapped.rt.dbgPrinting]);
    const missing=make();delete missing.x.dbg_ptr;let missingRefused=false;
    try{missing.rt.mount();}catch(error){missingRefused=error.message.includes('dbg_ptr');}
    checks.push(['missing new debug exports refuse mount before init',missingRefused]);
    let invalid=false;try{new RocEngineRuntime(normal.x,document.createElement('div'),{dbg:null});}catch(error){invalid=error.message.includes('dbg');}
    checks.push(['invalid dbg option refuses mount',invalid]);return checks;
  },[...protocolFixtureSection]);
  for(const [name,ok]of raw)check(name,ok);
  await page.close();
  console.log(`dbg-browser: ${count} contracts passed`);
} finally {await browser.close();await new Promise(resolve=>server.close(resolve));}
