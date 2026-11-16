import { socketPorts } from "./sockets.mjs";
import { notificationPorts } from "./notifications.mjs";
import { sharePorts } from "./share.mjs";
import { clipboardReadPorts } from "./clipboard-read.mjs";
import { geolocationPorts } from "./geolocation.mjs";
import { mediaPorts } from "./media.mjs";
import { displayPorts } from "./display.mjs";
import { datePorts } from "./dates.mjs";

// Make one set per mount: sockets, a wake lock and their observers never
// leak across instances. The camera element owns its own browser stream.
export function createPorts({ camera, fullscreenTarget }) {
  return {
    ...socketPorts(), ...notificationPorts(), ...sharePorts(),
    ...clipboardReadPorts(), ...geolocationPorts, ...mediaPorts(camera),
    ...displayPorts(fullscreenTarget), ...datePorts,
  };
}
