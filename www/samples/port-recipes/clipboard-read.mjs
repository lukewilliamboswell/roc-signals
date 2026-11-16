// Writing the clipboard uses the platform's Clipboard module. A permission
// dialog cannot be cancelled; one pending browser read bounds that lifetime.
export function clipboardReadPorts() {
  let reading = false;
  return {
    "example.org/recipes/clipboard-read": { call: async () => {
      if (!navigator.clipboard?.readText) throw new Error("Clipboard reading is unavailable");
      if (reading) throw new Error("A clipboard read is already pending");
      reading = true;
      try { return await navigator.clipboard.readText(); }
      finally { reading = false; }
    } },
  };
}
