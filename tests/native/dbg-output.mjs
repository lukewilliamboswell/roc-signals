// Actual native output, separate from SCM's application-behavior assertions.
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
import path from 'node:path';
if(process.argv.length!==4||process.argv[2]!=='--runner') throw Error('usage: node dbg-output.mjs --runner DBG_RUNNER');
const result=spawnSync(path.resolve(process.argv[3]),['tests/apps/dbg/specs/round-trip-dbg.scm'],{encoding:'utf8',timeout:120000,maxBuffer:1024*1024});
assert.ifError(result.error);assert.equal(result.signal,null);assert.equal(result.status,0,result.stdout+result.stderr);
const records=result.stdout.trim().split('\n').map(JSON.parse);
assert.equal(records.length,1);assert.equal(records[0].status,'passed');
const lines=result.stderr.split('\n').filter(line=>line.startsWith('[dbg'));
// Expected real reader sequence below, no settle evaluations.
assert.deepEqual(lines.filter(line=>line.includes('at: "reader"')).map(line=>Number(line.match(/count: (-?\d+)/)?.[1])),[0,1,0]);
assert.equal(lines.filter(line=>line.includes('at: "handler-first"')).length,1);
assert.equal(lines.filter(line=>line.includes('at: "handler-second"')).length,1);
assert.equal(lines.filter(line=>line.startsWith('[dbg task "dbg/echo"]')&&line.includes('at: "prepare"')).length,3);
assert.equal(lines.filter(line=>line.startsWith('[dbg task "dbg/echo"]')&&line.includes('at: "task"')).length,3);
console.log('native dbg: real reader evaluations once, handler order and three freshly prepared jobs');
