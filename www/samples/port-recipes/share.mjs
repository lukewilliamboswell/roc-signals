// A timed-out OS sheet can still be pending in the browser. Keep one slot
// until it settles, so a new click cannot accumulate permission promises.
export function sharePorts() {
  let sharing = false;
  return {
    "example.org/recipes/share": { call: async (message) => {
      if (typeof navigator.share !== "function") throw new Error("Web Share is unavailable");
      if (sharing) throw new Error("A share sheet is already pending");
      sharing = true;
      try { await navigator.share(message); return "Shared"; }
      catch (error) { if (error?.name === "AbortError") return "Cancelled"; throw error; }
      finally { sharing = false; }
    } },
  };
}
