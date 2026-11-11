// The Million-Row Explorer's port handler: a simulated live order feed, the
// example's own JavaScript. The platform's runtime knows nothing of it; the
// site passes this module's default export as the `ports` option of
// mountRocEngineApp, and the runtime checks it against the one port
// Feed.roc declares.
//
// The feed sets its own pace. A subscription delivers each message as a
// turn of its own, with no paint between the turns of a backlog, so the
// feed batches: every 250 ms it emits the orders placed since the last
// batch, a quarter of `per_second`. The port's delivery is `Every(4)`: up to
// four batches wait while the page is busy, and beyond them `emit` answers
// false. Orders are never replaced by newer ones, so a refused batch stays
// here and goes out with the next one. What waits here is bounded too: at
// most five seconds of orders; beyond that the oldest are dropped and
// counted, and every batch carries the count so the page can show it.
//
// Each order is { category, region, cents }: a category by its tag's name,
// a region by its name, as Feed.Sale declares.
const NS = "roc-signals.example/million-row-explorer";
const PACE_MS = 250;
const BACKLOG_SECONDS = 5;

const CATEGORIES = [
  // name, share of orders out of 1024, typical value and spread in cents
  ["Books", 140, 1800, 900],
  ["Electronics", 120, 21000, 12000],
  ["Fashion", 170, 7000, 4000],
  ["Garden", 90, 5500, 3500],
  ["Grocery", 210, 3800, 1800],
  ["Home", 110, 11000, 6000],
  ["Sports", 90, 8500, 5000],
  ["Toys", 94, 3200, 2000],
];
const REGIONS = [
  ["Northeast", 150], ["Southeast", 120], ["Midwest", 130], ["Southwest", 100], ["Mountain", 60], ["Pacific", 160],
  ["Canada", 70], ["Mexico", 40], ["United Kingdom", 70], ["Germany", 50], ["Nordics", 34], ["Australia", 40],
];

// A small seeded generator (mulberry32), so a page's feed is the same
// sequence every time it starts.
function generator(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pick = (table, r) => {
  let left = Math.floor(r * 1024);
  for (const row of table) {
    if (left < row[1]) return row;
    left -= row[1];
  }
  return table[table.length - 1];
};

function sale(random) {
  const [category, , centre, spread] = pick(CATEGORIES, random());
  const [region] = pick(REGIONS, random());
  // Three uniform draws: a bell around the category's typical value.
  const offset = spread * ((random() + random() + random()) / 1.5 - 1);
  const cents = Math.min(39999, Math.max(100, Math.round(centre + offset)));
  return { category, region, cents };
}

export default {
  [`${NS}/orders`]: {
    subscribe: ({ per_second: perSecond }, { emit }) => {
      const random = generator(2026);
      const cap = perSecond * BACKLOG_SECONDS;
      let waiting = [];
      let dropped = 0;
      let owed = 0;
      const timer = setInterval(() => {
        owed += (perSecond * PACE_MS) / 1000;
        const count = Math.floor(owed);
        owed -= count;
        for (let i = 0; i < count; i += 1) waiting.push(sale(random));
        if (waiting.length > cap) {
          dropped += waiting.length - cap;
          waiting = waiting.slice(waiting.length - cap);
        }
        if (waiting.length > 0 && emit({ sales: waiting, dropped })) waiting = [];
      }, PACE_MS);
      return () => clearInterval(timer);
    },
  },
};
