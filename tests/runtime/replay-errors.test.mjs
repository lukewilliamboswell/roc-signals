import test from 'node:test';
import assert from 'node:assert/strict';
import {applicationErrors} from '../browser/replay-errors.mjs';
test('only current worker-fault and exact printing-failure reports are passive',()=>{
  const ordinary=[
    'ordinary console error',
    'roc dbg: something failed',
    'roc dbg: printing failed',
    'roc dbg: printing failed and is off for this mount:',
    'roc dbg: printing failed and is off for this mount ; error',
    'prefix roc dbg: printing failed and is off for this mount: error',
    'roc worker fault: missing class prefix',
    'roc port fault [command] "a/log": command handler threw',
    'roc port fault [unsubscribe] "a/feed": the message nests containers more than 512 deep, so it was not sent',
  ];
  assert.deepEqual(applicationErrors([
    'roc dbg: printing failed and is off for this mount: Error: wrapped console',
    'roc worker fault [app_crash] in task "test": failed',
    'roc port fault [command] "a/log": the message nests containers more than 512 deep, so it was not sent',
    ...ordinary,
  ]),ordinary);
});
