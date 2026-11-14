export function notificationPorts() {
  let asking = false;
  return {
    "example.org/recipes/notification-permission": { call: async () => {
      if (!("Notification" in globalThis)) throw new Error("Notifications are unavailable");
      if (asking) throw new Error("Notification permission is already pending");
      asking = true;
      try {
        const permission = await Notification.requestPermission();
        switch (permission) {
        case "granted": return "Granted";
        case "denied": return "Denied";
        case "default": return "Dismissed";
        default: throw new Error("Unknown notification permission");
        }
      } finally { asking = false; }
    } },
    "example.org/recipes/notification-show": { command: ({ title, body }) => {
      if (!("Notification" in globalThis) || Notification.permission !== "granted") throw new Error("Notification permission is not granted");
      new Notification(title, { body });
    } },
  };
}
