// The JavaScript behind the notes sample's ports (Notes.roc): IndexedDB,
// which the platform does not model. The page passes the default export as
// the `ports` option of mountRocEngineApp. Each entry is plain functions of
// plain data: a call answers a value (or a promise of one), a subscription
// emits values until it is unsubscribed.
let opened = null;
const db = () =>
  (opened ??= new Promise((resolve, reject) => {
    const request = indexedDB.open("notes", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("notes", { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }));

// One transaction; resolves with the request's result when it commits.
const run = (mode, use) =>
  db().then(
    (d) =>
      new Promise((resolve, reject) => {
        const tx = d.transaction("notes", mode);
        const request = use(tx.objectStore("notes"));
        tx.oncomplete = () => resolve(request.result);
        tx.onerror = tx.onabort = () => reject(tx.error);
      }),
  );

// The store's revision: bumped by this tab's writes and by other tabs'.
let revision = 0n;
const listeners = new Set();
const bump = () => {
  revision += 1n;
  for (const emit of listeners) emit(revision);
};
const others = new BroadcastChannel("notes");
others.onmessage = bump;

export default {
  "example.org/notes/list": {
    call: async ({ prefix }, { signal }) => {
      const all = await run("readonly", (store) => store.getAll());
      signal.throwIfAborted();
      return all.filter((note) => note.title.startsWith(prefix));
    },
  },
  "example.org/notes/put": {
    call: async (note) => {
      await run("readwrite", (store) => store.put({ ...note, saved_ms: String(Date.now()) }));
      others.postMessage("changed");
      bump();
    },
  },
  "example.org/notes/changed": {
    subscribe: (_arg, { emit }) => {
      listeners.add(emit);
      emit(revision);
      return () => listeners.delete(emit);
    },
  },
};
