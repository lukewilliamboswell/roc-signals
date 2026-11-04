"""Generate the heterogeneous-tree gate app for representation D (Engine.roc)
and for the current platform-web engine.

Usage: gen.py SHELL PAGE OUT_D_DIR OUT_CUR_DIR

Shell: SHELL distinct components in a ternary tree, always mounted.
Pages: two routed trees of PAGE distinct components each; one is mounted.
Even-numbered components own a local state of a type chosen by k % 6;
odd-numbered ones are stateless and only derive from their prop.
"""
import sys, os

SHELL, PAGE = int(sys.argv[1]), int(sys.argv[2])
OUT_D, OUT_C = sys.argv[3], sys.argv[4]

# (roc type, init, step body over x, fmt body over x producing Str, class body producing Str)
KINDS = [
    ("U64", "{k}", "x + {s}", '"v{k}=${{x.to_str()}}"', 'if x % 3 == 0 "c{k} a" else "c{k} b"'),
    ("Str", '"a{k}"', 'if x == "a{k}" "b{k}" else "a{k}"', '"s{k}=${{x}}"', 'if x == "a{k}" "c{k} a" else "c{k} b"'),
    ("Bool", "Bool.False", "!x", 'if x "on{k}" else "off{k}"', 'if x "c{k} on" else "c{k} off"'),
    ("I64", "-{k}", "x - {s}", '"i{k}=${{x.to_str()}}"', 'if x % 2 == 0 "c{k} e" else "c{k} o"'),
    ("{{ n : U64, s : Str }}", '{{ n: {k}, s: "r{k}" }}', '{{ n: x.n + {s}, s: x.s }}', '"${{x.s}}#${{x.n.to_str()}}"', 'if x.n > {k}0 "c{k} big" else "c{k} small"'),
    ("[Red, Green, Blue]", "Red", "match x {{ Red => Green, Green => Blue, Blue => Red }}", 'match x {{ Red => "red{k}", Green => "green{k}", Blue => "blue{k}" }}', 'match x {{ Red => "c{k} r", Green => "c{k} g", Blue => "c{k} b" }}'),
]


def children(k, n):
    return [c for c in (3 * k + 1, 3 * k + 2, 3 * k + 3) if c < n]


def kind(k):
    return KINDS[(k // 2) % len(KINDS)]


def d_component(prefix, k, n):
    name = f"{prefix}{k}"
    kids = children(k, n)
    if k % 2 == 0:
        ty, init, step, fmt, cls = [t.format(k=k, s=k % 7 + 1) for t in kind(k)]
        # child prop derives from this state's formatted value
        kid_calls = "".join(f"\n            Gate.{prefix}{c}(v.map(Gate.{name}_fmt))," for c in kids)
        return f"""
{name}_fmt : {ty} -> Str
{name}_fmt = |x| {fmt}

{name} : Val(ctx, Str) -> Elem(ctx)
{name} = |prop| Engine.state({init}, |st| {{
    v = st.val()
    Engine.element("section", [Engine.class_v(v.map(|x| {cls})), Engine.test_id("{name}")], [
        Engine.text("Component {name}: "),
        Engine.text_v(v.map(Gate.{name}_fmt)),
        Engine.text_v(st.lift(prop)),
        Engine.element("button", [Engine.on_click(st.update(|x| {step})), Engine.test_id("b{name}")], [Engine.text("+")]),{kid_calls}
    ])
}})
"""
    else:
        kid_calls = "".join(f"\n        Gate.{prefix}{c}(prop.map(|p| \"${{p}}/{k}\")),"
                            for c in kids)
        return f"""
{name} : Val(ctx, Str) -> Elem(ctx)
{name} = |prop| Engine.element("div", [Engine.class("c{name}")], [
        Engine.text("Leaf {name} "),
        Engine.text_v(prop.map(|p| "{k}<${{p}}>")),{kid_calls}
    ])
"""


def c_component(prefix, k, n):
    name = f"{prefix}{k}"
    kids = children(k, n)
    if k % 2 == 0:
        ty, init, step, fmt, cls = [t.format(k=k, s=k % 7 + 1) for t in kind(k)]
        kid_calls = "".join(f"\n\t\t\t{prefix}{c}(v.map({name}_fmt))," for c in kids)
        return f"""
{name}_fmt : {ty} -> Str
{name}_fmt = |x| {fmt}

{name} : Signal(Str) -> Elem
{name} = |prop| Ui.state({init}, |st| {{
\tv = st.signal()
\tHtml.section("", [Html.class_attr_s(v.map(|x| {cls})), Html.test_id("{name}")], [
\t\tHtml.text("Component {name}: "),
\t\tHtml.text_s(v.map({name}_fmt)),
\t\tHtml.text_s(prop),
\t\tHtml.button_attrs("+", [Html.test_id("b{name}")], st.update(|x| {step})),{kid_calls}
\t])
}})
"""
    else:
        kid_calls = "".join(f"\n\t\t{prefix}{c}(prop.map(|p| \"${{p}}/{k}\"))," for c in kids)
        return f"""
{name} : Signal(Str) -> Elem
{name} = |prop| Html.div([Html.class_attr("c{name}")], [
\t\tHtml.text("Leaf {name} "),
\t\tHtml.text_s(prop.map(|p| "{k}<${{p}}>")),{kid_calls}
\t])
"""


def sparse_target(n, prefix):
    # Deepest stateful component with no children.
    for k in range(n - 1, -1, -1):
        if k % 2 == 0 and not children(k, n):
            return f"b{prefix}{k}"


os.makedirs(OUT_D, exist_ok=True)
os.makedirs(OUT_C, exist_ok=True)

d = ["## Generated heterogeneous tree for representation D.", "import Engine exposing [Elem, Val, Root]", "", "Gate := [].{"]
body = []
for prefix, n in (("s", SHELL), ("a", PAGE), ("b", PAGE)):
    for k in range(n):
        body.append(d_component(prefix, k, n))
body.append(f"""
view : {{}} -> Elem(Root)
view = |_| Engine.state(Bool.True, |route| Engine.element("main", [], [
    Engine.element("button", [Engine.on_click(route.update(|r| !r)), Engine.test_id("route")], [Engine.text("Switch")]),
    Gate.s0(Engine.const("shell")),
    Engine.when(route.val(), || Gate.a0(Engine.const("A")), || Gate.b0(Engine.const("B"))),
]))

sparse_target : Str
sparse_target = "{sparse_target(SHELL, 's')}"
""")
# indent body into the Gate block
for chunk in body:
    for line in chunk.split("\n"):
        d.append(("\t" + line) if line.strip() else "")
d.append("}")
open(os.path.join(OUT_D, "Gate.roc"), "w").write("\n".join(d) + "\n")

PF = os.path.relpath("/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a0bf066f512ab7d5d/platform-web/main.roc", os.path.realpath(OUT_C))
c = ['app [main] { pf: platform "' + PF + '" }',
     "", "import pf.Elem", "import pf.Html", "import pf.Signal", "import pf.Ui", ""]
for prefix, n in (("s", SHELL), ("a", PAGE), ("b", PAGE)):
    for k in range(n):
        c.append(c_component(prefix, k, n))
c.append("""
main : () -> Elem
main = || Ui.state(Bool.True, |route| Html.div([], [
\tHtml.button_attrs("Switch", [Html.test_id("route")], route.update(|r| !r)),
\ts0(Signal.const("shell")),
\tUi.when(route.signal(), || a0(Signal.const("A")), || b0(Signal.const("B"))),
]))
""")
open(os.path.join(OUT_C, "main.roc"), "w").write("\n".join(c) + "\n")
os.makedirs(os.path.join(OUT_C, "specs"), exist_ok=True)
tgt = sparse_target(SHELL, "s")
open(os.path.join(OUT_C, "specs", "sparse.scm"), "w").write(f"""(test "sparse update"
  (steps
    (mark-metrics)
    (click (test-id "{tgt}"))))
""")
open(os.path.join(OUT_C, "specs", "swap.scm"), "w").write("""(test "route swap"
  (steps
    (mark-metrics)
    (click (test-id "route"))
    (expect-visible (test-id "b0"))))
""")
open(os.path.join(OUT_C, "specs", "mount.scm"), "w").write("""(test "mount"
  (steps
    (mark-metrics)
    (expect-visible (test-id "s0"))))
""")
print("sparse target", tgt)
