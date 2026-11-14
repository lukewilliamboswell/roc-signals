// These runtime reports are passive observations/results, never page failures.
// Keep the existing worker-fault prefix and the exact debug observer diagnostic;
// nearby messages remain fatal so this cannot hide an ordinary app error.
export const WORKER_FAULT = 'roc worker fault [';
export const DBG_PRINT_FAILURE = 'roc dbg: printing failed and is off for this mount: ';
export function applicationErrors(messages) {
  return messages.filter(message=>!message.startsWith(WORKER_FAULT)&&!message.startsWith(DBG_PRINT_FAILURE));
}
