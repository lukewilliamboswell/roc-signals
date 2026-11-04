"""cur_conduit_variant.py SRC_DIR OUT_DIR N -- copy of the original Conduit
with host-bench specs mirroring apps/conduit's bench-N steps: mount (signed in
as kim, home), tags, feed (N generated articles), favorite (Article N/2),
favorite-response, tag-click. Each spec replays the earlier steps as setup
and marks metrics before the measured one."""
import sys, os, shutil, json
src, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = n // 2
k = m % 5

def article(i, fav=False, count=None):
    return {"slug": f"article-{i}", "title": f"Article {i}", "description": f"Description {i}.",
            "tagList": ["signals", "roc"], "createdAt": "2026-06-01T08:00:00.000Z", "favorited": fav,
            "favoritesCount": i % 5 if count is None else count,
            "author": {"username": "anna" if i % 2 == 0 else "max", "bio": "", "image": "https://example.test/a.png", "following": False}}

def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

tags = json.dumps({"tags": ["signals", "roc", "webdev"]}, separators=(',', ':'))
feed = json.dumps({"articles": [article(i) for i in range(n)], "articlesCount": n}, separators=(',', ':'))
fav_article = article(m, True, k + 1)
fav_article["body"] = "unused"
fav = json.dumps({"article": fav_article}, separators=(',', ':'))
steps = [
    ("mount", '(expect-visible (text "Loading articles..."))'),
    ("tags", f'(stub-http "tags" :url "/api/tags" :status 200 :body {q(tags)})\n    (run-effect 2)'),
    ("feed", f'(stub-http "feed" :url "/api/articles?limit=20&offset=0" :status 200 :body {q(feed)})\n    (run-effect 1)'),
    ("favorite", f'(click (role button :name "Favorite Article {m} ({k})"))'),
    ("favorite-response", f'(stub-http "fav" :url "/api/articles/article-{m}/favorite" :status 200 :body {q(fav)})\n    (run-effect 3)'),
    ("tag-click", '(click (role link :name "signals"))'),
]
shutil.rmtree(out, ignore_errors=True)
shutil.copytree(src, out)
sd = os.path.join(out, 'specs')
shutil.rmtree(sd)
os.makedirs(sd)
setup = '''  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/"))'''
for i, (name, step) in enumerate(steps):
    lines = []
    for j in range(1, i):
        lines.append(steps[j][1])
    if name == "mount":
        body = f'    (mark-metrics)\n    {step}'
    else:
        # the measured step's setup half (stub) stays before the mark
        parts = step.split('\n    ')
        pre = parts[:-1]
        body = '\n    '.join(lines + pre + ['(mark-metrics)', parts[-1]])
        body = '    ' + body
    open(os.path.join(sd, name + '.scm'), 'w').write(f'(test "{name}"\n{setup}\n  (steps\n{body}))\n')
print(f"{len(steps)} specs -> {sd}")
