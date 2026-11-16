// These runtime reports are passive observations/results, never page failures.
// Keep the existing worker-fault prefix, the exact debug observer diagnostic
// and the exact report of a port command the engine did not send (its
// message nested past the port format's bound, which the spec observes as
// nothing sent); nearby messages remain fatal so this cannot hide an
// ordinary app error.
export const WORKER_FAULT = 'roc worker fault [';
export const DBG_PRINT_FAILURE = 'roc dbg: printing failed and is off for this mount: ';
export const PORT_UNSENT = ['roc port fault [command] "', '": the message nests containers more than 512 deep, so it was not sent'];
const unsent = message => message.startsWith(PORT_UNSENT[0]) && message.endsWith(PORT_UNSENT[1]) && message.length > PORT_UNSENT[0].length + PORT_UNSENT[1].length;
export function applicationErrors(messages) {
  return messages.filter(message=>!message.startsWith(WORKER_FAULT)&&!message.startsWith(DBG_PRINT_FAILURE)&&!unsent(message));
}
