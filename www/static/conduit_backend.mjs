// Deterministic in-page RealWorld (Conduit) API backend for examples/conduit.
//
// Response shapes follow the RealWorld API spec
// (https://docs.realworld.show/specifications/backend/): user/profile/article/
// comment envelopes, `{"errors": {...}}` validation bodies with status 422,
// and limit/offset pagination with `articlesCount` reporting the total match
// count. The list endpoint intentionally omits `body` on article summaries,
// matching the spec's Multiple Articles example — the app's list DTO must not
// require it, which keeps the app compatible with the weakest conformant
// backend.
//
// Current surface: the read endpoints plus login. Register, user update,
// article/comment/favorite/follow mutations land alongside the app phases
// that exercise them (wip/REALWORLD_DEMO_PLAN.md).
//
// Everything is seeded and in-memory: no clock, no randomness, so native and
// JS assertions can rely on exact values. Unknown URIs return null so the
// public example task-handler chain (and later a real-fetch fallback) can
// take them.

import {
  decodeHttpRequestPayload,
  HttpTask,
  httpHeaderValue,
  httpJsonResponse,
  httpTaskError,
} from "./signals.mjs";

const bodyDecoder = new TextDecoder();

const SEED_BASE_UTC_MS = Date.UTC(2026, 5, 1, 8, 0, 0);

const SEED_USERS = [
  {
    username: "anna",
    email: "anna@conduit.test",
    password: "secret-anna",
    bio: "Signals platform notes and release engineering.",
    image: "https://example.test/avatars/anna.png",
    follows: [],
  },
  {
    username: "max",
    email: "max@conduit.test",
    password: "secret-max",
    bio: "Writes about queues, latency, and dashboards.",
    image: "https://example.test/avatars/max.png",
    follows: [],
  },
  {
    username: "kim",
    email: "kim@conduit.test",
    password: "secret-kim",
    bio: "Reader. Occasionally files very detailed bug reports.",
    image: "https://example.test/avatars/kim.png",
    follows: ["anna"],
  },
];

const SEED_TAG_SETS = [
  ["signals", "webdev"],
  ["roc", "release"],
  ["performance", "signals"],
  ["testing"],
  ["webdev", "release"],
  ["roc", "signals"],
];

const SEED_TOPICS = [
  "Keyed lists without tears",
  "Budgeting patches per interaction",
  "Latest-wins request replacement",
  "Storage keys on a shared origin",
  "Deep links that survive reloads",
  "Markdown to Elem nodes",
  "Error envelopes worth rendering",
  "Pagination that stays honest",
];

function seedToken(username) {
  return `jwt.conduit.${username}`;
}

function isoAfterHours(hours) {
  return new Date(SEED_BASE_UTC_MS + hours * 3_600_000).toISOString();
}

function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function createConduitBackend() {
  const users = new Map();
  for (const seed of SEED_USERS) {
    users.set(seed.username, {
      username: seed.username,
      email: seed.email,
      password: seed.password,
      bio: seed.bio,
      image: seed.image,
      following: new Set(seed.follows),
      token: seedToken(seed.username),
    });
  }

  const articles = [];
  for (let index = 1; index <= 23; index += 1) {
    const topic = SEED_TOPICS[(index - 1) % SEED_TOPICS.length];
    const title = `${topic} #${index}`;
    const author = index % 3 === 0 ? "max" : "anna";
    const favoritedBy = new Set(index % 4 === 1 ? ["kim"] : []);
    articles.push({
      slug: slugify(title),
      title,
      description: `Field notes ${index}: ${topic.toLowerCase()}.`,
      body: [
        `# ${topic}`,
        "",
        `Entry ${index} in the conduit seed series.`,
        "",
        "- observed behavior",
        "  - measured, not guessed",
        "- follow-up",
        "",
        "```",
        `signals check --entry ${index}`,
        "```",
      ].join("\n"),
      tagList: [...SEED_TAG_SETS[(index - 1) % SEED_TAG_SETS.length]],
      createdAt: isoAfterHours(index * 7),
      updatedAt: isoAfterHours(index * 7),
      author,
      favoritedBy,
    });
  }

  const comments = new Map();
  comments.set(articles[0].slug, [
    {
      id: 1,
      createdAt: isoAfterHours(30),
      updatedAt: isoAfterHours(30),
      body: "Tried this against the ops dashboard — the budgets held.",
      author: "kim",
    },
    {
      id: 2,
      createdAt: isoAfterHours(31),
      updatedAt: isoAfterHours(31),
      body: "Second run confirms it.",
      author: "max",
    },
  ]);

  return { users, articles, comments, nextCommentId: 3 };
}

function userByToken(backend, headers) {
  const header = httpHeaderValue(headers, "authorization");
  if (!header.startsWith("Token ")) {
    return null;
  }
  const token = header.slice("Token ".length).trim();
  for (const user of backend.users.values()) {
    if (user.token === token) {
      return user;
    }
  }
  return null;
}

function profileJson(backend, username, viewer) {
  const user = backend.users.get(username);
  if (!user) {
    return null;
  }
  return {
    username: user.username,
    bio: user.bio,
    image: user.image,
    following: viewer ? viewer.following.has(user.username) : false,
  };
}

function articleSummaryJson(backend, article, viewer) {
  return {
    slug: article.slug,
    title: article.title,
    description: article.description,
    tagList: [...article.tagList],
    createdAt: article.createdAt,
    updatedAt: article.updatedAt,
    favorited: viewer ? article.favoritedBy.has(viewer.username) : false,
    favoritesCount: article.favoritedBy.size,
    author: profileJson(backend, article.author, viewer),
  };
}

function articleJson(backend, article, viewer) {
  return {
    ...articleSummaryJson(backend, article, viewer),
    body: article.body,
  };
}

function commentJson(backend, comment, viewer) {
  return {
    id: comment.id,
    createdAt: comment.createdAt,
    updatedAt: comment.updatedAt,
    body: comment.body,
    author: profileJson(backend, comment.author, viewer),
  };
}

function userJson(user) {
  return {
    email: user.email,
    token: user.token,
    username: user.username,
    bio: user.bio,
    image: user.image,
  };
}

function errorResponse(status, errors) {
  return httpJsonResponse({ errors }, { status });
}

function notFound() {
  return errorResponse(404, { body: ["not found"] });
}

function unauthorized() {
  return errorResponse(401, { body: ["unauthorized"] });
}

function paginate(query, matching) {
  const limitRaw = Number.parseInt(query.get("limit") ?? "", 10);
  const offsetRaw = Number.parseInt(query.get("offset") ?? "", 10);
  const limit = Number.isFinite(limitRaw) && limitRaw >= 0 ? limitRaw : 20;
  const offset = Number.isFinite(offsetRaw) && offsetRaw >= 0 ? offsetRaw : 0;
  return matching.slice(offset, offset + limit);
}

function byNewestFirst(left, right) {
  if (left.createdAt === right.createdAt) {
    return left.slug < right.slug ? 1 : -1;
  }
  return left.createdAt < right.createdAt ? 1 : -1;
}

function listArticles(backend, query, viewer) {
  const tag = query.get("tag");
  const author = query.get("author");
  const favorited = query.get("favorited");
  const matching = backend.articles
    .filter((article) => {
      if (tag && !article.tagList.includes(tag)) {
        return false;
      }
      if (author && article.author !== author) {
        return false;
      }
      if (favorited && !article.favoritedBy.has(favorited)) {
        return false;
      }
      return true;
    })
    .sort(byNewestFirst);
  return httpJsonResponse({
    articles: paginate(query, matching).map((article) => articleSummaryJson(backend, article, viewer)),
    articlesCount: matching.length,
  });
}

function feedArticles(backend, query, viewer) {
  if (!viewer) {
    return unauthorized();
  }
  const matching = backend.articles
    .filter((article) => viewer.following.has(article.author))
    .sort(byNewestFirst);
  return httpJsonResponse({
    articles: paginate(query, matching).map((article) => articleSummaryJson(backend, article, viewer)),
    articlesCount: matching.length,
  });
}

function singleArticle(backend, slug, viewer) {
  const article = backend.articles.find((candidate) => candidate.slug === slug);
  if (!article) {
    return notFound();
  }
  return httpJsonResponse({ article: articleJson(backend, article, viewer) });
}

function articleComments(backend, slug, viewer) {
  const article = backend.articles.find((candidate) => candidate.slug === slug);
  if (!article) {
    return notFound();
  }
  const entries = backend.comments.get(slug) ?? [];
  return httpJsonResponse({ comments: entries.map((comment) => commentJson(backend, comment, viewer)) });
}

function popularTags(backend) {
  const counts = new Map();
  for (const article of backend.articles) {
    for (const tag of article.tagList) {
      counts.set(tag, (counts.get(tag) ?? 0) + 1);
    }
  }
  const tags = [...counts.entries()]
    .sort(([leftTag, leftCount], [rightTag, rightCount]) =>
      leftCount === rightCount ? (leftTag < rightTag ? -1 : 1) : rightCount - leftCount,
    )
    .map(([tagName]) => tagName);
  return httpJsonResponse({ tags });
}

function login(backend, bodyText) {
  let parsed;
  try {
    parsed = JSON.parse(bodyText);
  } catch {
    return errorResponse(422, { body: ["can't be parsed"] });
  }
  const email = parsed?.user?.email;
  const password = parsed?.user?.password;
  if (!email) {
    return errorResponse(422, { email: ["can't be blank"] });
  }
  if (!password) {
    return errorResponse(422, { password: ["can't be blank"] });
  }
  for (const user of backend.users.values()) {
    if (user.email === email && user.password === password) {
      return httpJsonResponse({ user: userJson(user) });
    }
  }
  return errorResponse(422, { "email or password": ["is invalid"] });
}

function register(backend, bodyText) {
  let parsed;
  try {
    parsed = JSON.parse(bodyText);
  } catch {
    return errorResponse(422, { body: ["can't be parsed"] });
  }
  const username = parsed?.user?.username;
  const email = parsed?.user?.email;
  const password = parsed?.user?.password;
  if (!username) {
    return errorResponse(422, { username: ["can't be blank"] });
  }
  if (!email) {
    return errorResponse(422, { email: ["can't be blank"] });
  }
  if (!password) {
    return errorResponse(422, { password: ["can't be blank"] });
  }
  if (backend.users.has(username)) {
    return errorResponse(422, { username: ["has already been taken"] });
  }
  const user = {
    username,
    email,
    password,
    bio: "",
    image: "",
    following: new Set(),
    token: seedToken(username),
  };
  backend.users.set(username, user);
  return httpJsonResponse({ user: userJson(user) });
}

function updateUser(backend, viewer, bodyText) {
  let parsed;
  try {
    parsed = JSON.parse(bodyText);
  } catch {
    return errorResponse(422, { body: ["can't be parsed"] });
  }
  const updates = parsed?.user ?? {};
  for (const field of ["email", "bio", "image", "password", "username"]) {
    if (typeof updates[field] === "string" && updates[field] !== "") {
      viewer[field] = updates[field];
    }
  }
  return httpJsonResponse({ user: userJson(viewer) });
}

function isConduitPath(path) {
  return (
    path === "/api/articles" ||
    path.startsWith("/api/articles/") ||
    path === "/api/tags" ||
    path === "/api/user" ||
    path === "/api/users" ||
    path.startsWith("/api/users/") ||
    path.startsWith("/api/profiles/")
  );
}

function routeConduit(backend, { method, path, query, viewer, bodyText }) {
  const segments = path.split("/").filter((segment) => segment.length > 0);

  if (method === "GET" && path === "/api/articles") {
    return listArticles(backend, query, viewer);
  }
  if (method === "GET" && path === "/api/articles/feed") {
    return feedArticles(backend, query, viewer);
  }
  if (method === "GET" && segments.length === 3 && segments[1] === "articles") {
    return singleArticle(backend, segments[2], viewer);
  }
  if (method === "GET" && segments.length === 4 && segments[1] === "articles" && segments[3] === "comments") {
    return articleComments(backend, segments[2], viewer);
  }
  if (method === "GET" && path === "/api/tags") {
    return popularTags(backend);
  }
  if (method === "GET" && segments.length === 3 && segments[1] === "profiles") {
    const profile = profileJson(backend, segments[2], viewer);
    return profile ? httpJsonResponse({ profile }) : notFound();
  }
  if (method === "POST" && path === "/api/users/login") {
    return login(backend, bodyText);
  }
  if (method === "POST" && path === "/api/users") {
    return register(backend, bodyText);
  }
  if (method === "PUT" && path === "/api/user") {
    return viewer ? updateUser(backend, viewer, bodyText) : unauthorized();
  }
  if (method === "GET" && path === "/api/user") {
    return viewer ? httpJsonResponse({ user: userJson(viewer) }) : unauthorized();
  }

  return notFound();
}

export function createConduitTaskHandler({ backend = createConduitBackend(), latencyMs = 0 } = {}) {
  return function conduitTaskHandler({ name, request, signal }) {
    if (typeof name !== "string" || !name.startsWith(HttpTask.namePrefix)) {
      return null;
    }

    let decoded;
    try {
      decoded = decodeHttpRequestPayload(request);
    } catch (err) {
      throw httpTaskError("unsupported", err?.message ?? err);
    }

    const [path, queryText = ""] = String(decoded.uri).split("?");
    if (!isConduitPath(path)) {
      return null;
    }

    const response = routeConduit(backend, {
      method: decoded.method.toUpperCase(),
      path,
      query: new URLSearchParams(queryText),
      viewer: userByToken(backend, decoded.headers),
      bodyText: bodyDecoder.decode(decoded.body),
    });

    if (latencyMs <= 0) {
      return response;
    }

    return new Promise((resolve, reject) => {
      if (signal?.aborted) {
        reject(httpTaskError("canceled"));
        return;
      }
      const timer = setTimeout(() => resolve(response), latencyMs);
      signal?.addEventListener?.(
        "abort",
        () => {
          clearTimeout(timer);
          reject(httpTaskError("canceled"));
        },
        { once: true },
      );
    });
  };
}
