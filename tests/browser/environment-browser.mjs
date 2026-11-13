import { installProtocolFixture } from "./protocol-fixture.mjs";
// Browser facts cross the ordinary boot and effect boundaries. These cases
// independently inspect bytes, callback-time sampling and malformed wire data.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
const opts = parseArgs(process.argv.slice(2));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const file = files[path.basename(new URL(req.url, "http://x").pathname)];
  res.writeHead(200, { "content-type": file?.endsWith("wasm") ? "application/wasm" : file ? "text/javascript" : "text/html" });
  res.end(file ? fs.readFileSync(file) : "<!doctype html><body></body>");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: opts.chrome });
let failures = 0;
const check = (name, ok) => { console.log(`${ok ? "ok  " : "FAIL"} ${name}`); if (!ok) failures++; };
try {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await installProtocolFixture(page);
  const results = await page.evaluate(async () => {
    const { RocEngineRuntime, PROTOCOL_VERSION, pageImports } = await import("./runtime.mjs");
    const out = [];
    const check = (name, ok) => out.push([name, !!ok]);
    const join = parts => { const result = new Uint8Array(parts.reduce((n,p) => n+p.length,0)); let at=0; for (const p of parts) { result.set(p,at); at+=p.length; } return result; };
    const u32 = n => { const b=new Uint8Array(4); new DataView(b.buffer).setUint32(0,n,true); return b; };
    const i64 = n => { const b=new Uint8Array(8); new DataView(b.buffer).setBigInt64(0,n,true); return b; };
    const str = s => { const b=new TextEncoder().encode(s); return join([u32(b.length),b]); };
    const section = (tag,body) => join([new Uint8Array([tag]),u32(body.length),body]);
    const min = -(1n<<63n), max=(1n<<63n)-1n;
    const zone = { name:"UTC",from_ms:min,until_ms:max,offsets:[{from_ms:min,minutes:0}] };
    const defaults = { now:()=>0n, seed:()=>new Uint8Array(16), languages:()=>["en-US"], timeZone:()=>zone };
    const sections = bytes => { const parts=new Map(); for(let at=0;at<bytes.length;) { const tag=bytes[at],n=new DataView(bytes.buffer,bytes.byteOffset+at+1,4).getUint32(0,true); parts.set(tag,bytes.slice(at+5,at+5+n)); at+=5+n; } return parts; };
    function capture(environment={}, manual=false, days=366) {
      const memory=new WebAssembly.Memory({initial:2});
      const declarations=join([section(2,u32(0)),section(5,u32(0)),section(6,u32(0)),section(10,new Uint8Array([days&255,days>>8])),section(11,u32(0)), __protocolFixtureSection]);
      new Uint8Array(memory.buffer).set(declarations);
      let mounted=false, length=0, boot;
      const x={ memory,protocol_version:()=>PROTOCOL_VERSION,boot_keys:()=>{},cmd_ptr:()=>0,cmd_len:()=>mounted?0:declarations.length,
        payload_reserve:n=>{length=n;return 65536;},init:()=>{boot=new Uint8Array(memory.buffer,65536,length).slice();mounted=true;},files_released:()=>0,metric:()=>0n,work_len:()=>0,fault:()=>0,drop:()=>{} };
      const root=document.createElement("div"); document.body.append(root);
      const readers={...defaults,...environment};
      for(const key of Object.keys(readers))if(readers[key]===undefined)delete readers[key];
      const runtime=new RocEngineRuntime(x,root,{environment:readers,manual});
      runtime.mount();
      const delivered=[]; runtime.deliver=(_node,id,payload)=>delivered.push({id,bytes:Array.from(payload)});
      return {runtime,delivered,boot,close:()=>{runtime.unmount();root.remove();}};
    }
    let reads=0,daysSeen;
    const owned=new Uint8Array(Array.from({length:16},(_,i)=>i));
    const f=capture({now:()=>{reads++;return min;},seed:()=>owned,languages:()=>["", "é".repeat(32)],timeZone:days=>{daysSeen=days;return {name:"x",from_ms:1n,until_ms:1n,offsets:[{from_ms:1n,minutes:-2147483648}]};}});
    const parts=sections(f.boot);
    check("boot sections are ordered and carry exact signed I64 and owned seed bytes", [...parts.keys()].join()==="1,2,3,4,6,7,8,9,10,11" && new DataView(parts.get(7).buffer).getBigInt64(0,true)===min && parts.get(8).every((b,i)=>b===i) && reads===1 && daysSeen===366);
    check("injected point zone need not contain mount time", !f.runtime.poisoned && parts.get(10).length===37);
    f.close();
    let defaultReads=0;
    const defaultZone=capture({now:()=>{defaultReads++;return 1234;},timeZone:undefined},false,0);
    const defaultParts=sections(defaultZone.boot);
    check("default zone uses the single captured mount time and declared zero-day span",defaultReads===1&&new DataView(defaultParts.get(10).buffer).getBigInt64(4+new DataView(defaultParts.get(10).buffer).getUint32(0,true),true)===1234n);
    defaultZone.close();
    let invalidDays=false;try{capture({},false,7306);}catch(e){invalidDays=e.message.includes("section 10");}
    check("an invalid declared zone span is refused before mount",invalidDays);
    const invalids=[{now:()=>Number.MAX_SAFE_INTEGER+1},{now:()=>1.1},{now:()=>max+1n},{now:()=>"0"},{seed:()=>new Uint8Array(15)},{seed:()=>[]},{languages:()=>[]},{languages:()=>Array(17).fill("en")},{languages:()=>["é".repeat(33)]},{timeZone:()=>({...zone,name:"x".repeat(65)})},{timeZone:()=>({...zone,offsets:[]})},{timeZone:()=>({...zone,offsets:[{from_ms:0n,minutes:0}]})},{timeZone:()=>({...zone,until_ms:min-1n})}];
    check("bad injected facts refuse before init",invalids.every(env=>{try{const f=capture(env);f.close();return false;}catch{return true;}}));
    const noEntropy=Object.getOwnPropertyDescriptor(globalThis,"crypto");
    try { Object.defineProperty(globalThis,"crypto",{value:undefined,configurable:true}); let refused=false; try {capture({seed:undefined});}catch(e){refused=e.message.includes("entropy");} check("absent cryptographic entropy refuses mount",refused); }
    finally { Object.defineProperty(globalThis,"crypto",noEntropy); }
    let clock=100n;
    const manual=capture({now:()=>clock},true);
    manual.runtime.perform({op:"timer",id:1,ms:999999}); clock=-400n; manual.runtime.runEffect(1);
    manual.runtime.perform({op:"interval",id:2,ms:999999}); clock=max; manual.runtime.tick(2); clock=min; manual.runtime.tick(2);
    const times = delivered => delivered.map(e=>new DataView(new Uint8Array(e.bytes).buffer).getBigInt64(1,true).toString());
    check("manual timers and interval ticks stamp current full-range clock without advancing it",times(manual.delivered).join()===[-400n,max,min].map(String).join() && clock===min && manual.delivered.every(e=>e.bytes.length===9&&e.bytes[0]===5));
    manual.close();
    const real=capture({now:()=>clock});
    clock=1n; real.runtime.perform({op:"timer",id:3,ms:10}); clock=-77n;
    await new Promise(resolve=>setTimeout(resolve,30));
    check("production timer samples callback time rather than issue time",times(real.delivered).join()==="-77");
    real.runtime.busy=true; clock=19n; real.runtime.perform({op:"timer",id:4,ms:0}); await new Promise(resolve=>setTimeout(resolve,20)); clock=20n; real.runtime.busy=false; real.runtime.drainQueue();
    check("queued timer retains callback sample across a busy batch",times(real.delivered).join()==="-77,19");
    real.close();
    let callbackClock=0n;
    const interval=capture({now:()=>callbackClock});
    interval.runtime.perform({op:"interval",id:5,ms:10});callbackClock=-42n;await new Promise(resolve=>setTimeout(resolve,35));
    check("production interval samples callback clock",interval.delivered.length>=1&&times(interval.delivered).every(t=>t==="-42"));interval.close();
    let broken=false;
    const failing=capture({now:()=>{if(broken)throw Error("clock failed");return 0n;}});broken=true;failing.runtime.perform({op:"interval",id:6,ms:1});await new Promise(resolve=>setTimeout(resolve,15));
    check("a failing callback reader contains the instance and cancels interval",failing.runtime.poisoned?.class==="executor"&&failing.runtime.live.size===0&&failing.delivered.length===0);failing.close();
    // The real decoder must reject malformed data before stale-result routing.
    const module=await WebAssembly.compile(await(await fetch("app.wasm")).arrayBuffer());
    const fresh=async()=> (await WebAssembly.instantiate(module,pageImports(module))).exports;
    const baseFixture=capture(); const base=sections(baseFixture.boot); baseFixture.close();
    const boot=changes=>join([...base].map(([tag,body])=>section(tag,changes.get(tag)??body)));
    const stage=(x,bytes)=>{const ptr=x.payload_reserve(bytes.length);new Uint8Array(x.memory.buffer,ptr,bytes.length).set(bytes);};
    const bad=[ [7,new Uint8Array(7)], [7,new Uint8Array(9)], [8,new Uint8Array(15)], [8,new Uint8Array(17)], [9,u32(0)], [9,join([u32(17),...Array(17).fill(str("en"))])], [9,join([u32(1),str("x".repeat(65))])], [9,join([u32(1),u32(1),new Uint8Array([255])])], [10,join([str("UTC"),i64(1n),i64(0n),u32(1),i64(1n),u32(0)])], [10,join([str("UTC"),i64(0n),i64(1n),u32(0)])], [10,join([str("UTC"),i64(0n),i64(1n),u32(1),i64(1n),u32(0)])], [10,join([str("UTC"),i64(0n),i64(1n),u32(2),i64(0n),u32(0),i64(0n),u32(1)])], [10,join([str("UTC"),i64(0n),i64(1n),u32(2),i64(0n),u32(0),i64(2n),u32(1)])], [10,join([str("x".repeat(65)),i64(0n),i64(1n),u32(1),i64(0n),u32(0)])] ];
    for(const [tag,body] of bad){const x=await fresh();x.boot_keys();stage(x,boot(new Map([[tag,body]])));let rejected=false;try{x.init();}catch{const msg=new TextDecoder().decode(new Uint8Array(x.memory.buffer,x.err_ptr(),x.err_len()));rejected=x.fault()===1&&msg.includes(`section ${tag}`);}check(`real boot decoder rejects malformed section ${tag} (${body.length} bytes)`,rejected);}
    for(const payload of [new Uint8Array([5]),new Uint8Array([5,0]),new Uint8Array(10).fill(5),join([new Uint8Array([5]),i64(min)]),join([new Uint8Array([5]),i64(max)])]){
      const x=await fresh();x.boot_keys();stage(x,boot(new Map()));x.init();stage(x,payload);let accepted=true;try{x.event(0xffffffff,999999);}catch{accepted=false;}check(`Fired payload length ${payload.length} ${payload.length===9?"accepts signed timestamp":"is rejected"}`,payload.length===9?accepted:!accepted&&x.fault()===1);if(accepted)x.drop();
    }
    return out;
  });
  for(const [name,ok] of results)check(name,ok);
  for(const timezoneId of ["UTC","Australia/Sydney"]){
    await page.send("Emulation.setTimezoneOverride",{timezoneId});
    const result=await page.evaluate(async()=>{const{probeTimeZone}=await import("./environment.mjs");const at=BigInt(Date.UTC(2025,0,1));let reads=0;const start=performance.now();const z=probeTimeZone(366,at,{offsetAt:t=>{reads++;return -new Date(Number(t)).getTimezoneOffset();}});return {name:z.name,span:[String(z.from_ms),String(z.until_ms)],count:z.offsets.length,exact:z.offsets.every((o,i)=>o.minutes===-new Date(Number(o.from_ms)).getTimezoneOffset()&&(i===0||z.offsets[i-1].minutes===-new Date(Number(o.from_ms-1n)).getTimezoneOffset())),reads,ms:performance.now()-start};});
    check(`Chrome ${timezoneId} daily probe and millisecond transitions`,result.name===timezoneId&&result.exact&&result.count===(timezoneId==="UTC"?1:5)&&result.span.join()==="1704067200000,1767312000000");
    console.log(`    ${timezoneId}: ${result.count} offsets, ${result.reads} Date reads, ${result.ms.toFixed(2)} ms`);
  }
  await ctx.close();
}finally{await browser.close();server.close();}
if(failures)process.exitCode=1;
