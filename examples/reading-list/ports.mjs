// The Reading List's port handlers: the JavaScript this app's author writes,
// and the only JavaScript of its own the app has. The platform's runtime
// (runtime.mjs) knows nothing of it; the page that mounts the app passes
// this module's default export as the `ports` option of mountRocEngineApp,
// and the runtime checks it against the ports Store.roc registers, one
// handler per port, before the app starts.
//
// The books live in IndexedDB, one record per book, each exactly the object
// that crosses the port (Store.Book): { id, title, author, shelf, added_ms },
// with `shelf` a tag name ("WantToRead") and `added_ms` a signed decimal
// string, as an I64 crosses. Every handler takes and answers plain data; nothing here
// touches the page or the app's state.
const NS = "roc-signals.example/reading-list";
const DATABASE = "roc-signals.example/reading-list";
const BOOKS = "books";

let opened = null;
const database = () =>
  (opened ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(BOOKS, { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }));

// One transaction on the books, resolved with the request's result once the
// transaction has committed. IndexedDB runs transactions on one store in the
// order they are created, which the convergence below relies on.
const transact = (mode, use) =>
  database().then(
    (db) =>
      new Promise((resolve, reject) => {
        const tx = db.transaction(BOOKS, mode);
        const request = use(tx.objectStore(BOOKS));
        tx.oncomplete = () => resolve(request.result);
        tx.onerror = tx.onabort = () => reject(tx.error);
      }),
  );

const readAll = () => transact("readonly", (books) => books.getAll());

// The `stored` subscriptions of this tab, and the channel on which every tab
// of this origin announces that it wrote. After any write, here or in
// another tab, each subscription receives the books as a fresh transaction
// reads them; that read sees every write committed before it, so the last
// message a tab receives is the store as it now is.
const subscribers = new Set();
const others = new BroadcastChannel(DATABASE);

const publish = () =>
  readAll().then(
    (books) => {
      for (const emit of subscribers) emit(books);
    },
    (error) => console.error("reading list: could not read the books", error),
  );
others.onmessage = publish;

// After this tab's write: tell the other tabs, and this one.
const written = () => {
  others.postMessage("written");
  return publish();
};

export default {
  [`${NS}/load`]: { call: () => readAll() },

  [`${NS}/add`]: {
    call: async (book) => {
      await transact("readwrite", (books) => books.add(book));
      written();
      return book;
    },
  },

  // The app has already shown these changes. A command's failure reaches
  // the console and the mount's onPortFault, never the app, so whether or
  // not the write happened, this tab is sent the books as stored: a write
  // that failed is undone on the page too.
  [`${NS}/put`]: {
    command: (book) => transact("readwrite", (books) => books.put(book)).finally(written),
  },

  [`${NS}/remove`]: {
    command: ({ id }) => transact("readwrite", (books) => books.delete(id)).finally(written),
  },

  [`${NS}/stored`]: {
    subscribe: (_arg, { emit }) => {
      subscribers.add(emit);
      return () => subscribers.delete(emit);
    },
  },
};
