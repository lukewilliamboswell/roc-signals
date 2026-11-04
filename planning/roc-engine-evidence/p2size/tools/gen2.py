"""Generate the Phase 1b heterogeneous-tree gate app (same tree as p1b/gen.py)
in the component-boundary form used by the R2 engines.

Usage: gen2.py SHELL PAGE OUT_DIR [MODE]

MODE "body" (default): every component is a wrapper
    sK = |prop| Engine.component(prop, Body(Gate.sK_body))
over a monomorphic body `sK_body : Val(P, Str) -> Elem(P)`.
"""
import sys, os

SHELL, PAGE = int(sys.argv[1]), int(sys.argv[2])
OUT = sys.argv[3]
MODE = sys.argv[4] if len(sys.argv) > 4 else "body"

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


EXTRA = [
    ("U32", "{k}", "x + {s}", '"w{k}=${{x.to_str()}}"', 'if x % 3 == 0 "c{k} a" else "c{k} b"'),
    ("I32", "-{k}", "x - {s}", '"j{k}=${{x.to_str()}}"', 'if x % 2 == 0 "c{k} e" else "c{k} o"'),
    ("U16", "{k}", "x + {s}", '"h{k}=${{x.to_str()}}"', 'if x % 3 == 0 "c{k} a" else "c{k} b"'),
    ("{{ a : U64, b : Bool }}", '{{ a: {k}, b: Bool.True }}', '{{ a: x.a + {s}, b: !x.b }}', '"${{x.a.to_str()}}"', 'if x.b "c{k} y" else "c{k} n"'),
    ("[Up, Down]", "Up", "match x {{ Up => Down, Down => Up }}", 'match x {{ Up => "up{k}", Down => "down{k}" }}', 'match x {{ Up => "c{k} u", Down => "c{k} d" }}'),
    ("{{ t : Str, c : U8 }}", '{{ t: "t{k}", c: 0 }}', '{{ t: x.t, c: x.c + 1 }}', '"${{x.t}}${{x.c.to_str()}}"', 'if x.c > 2 "c{k} hi" else "c{k} lo"'),
]
if os.environ.get("KINDS12"):
    KINDS = KINDS + EXTRA


def kind(k):
    return KINDS[(k // 2) % len(KINDS)]


def component(prefix, k, n):
    name = f"{prefix}{k}"
    kids = children(k, n)
    wrapper = f"""
{name} : Val(ctx, Str) -> Elem(ctx)
{name} = |prop| Engine.component(prop, Body(Gate.{name}_body))
"""
    if k % 2 == 0:
        ty, init, step, fmt, cls = [t.format(k=k, s=k % 7 + 1) for t in kind(k)]
        kid_calls = "".join(f"\n            Gate.{prefix}{c}(v.map(Gate.{name}_fmt))," for c in kids)
        return wrapper + f"""
{name}_fmt : {ty} -> Str
{name}_fmt = |x| {fmt}

{name}_body : Val(P, Str) -> Elem(P)
{name}_body = |prop| Engine.state({init}, |st| {{
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
        return wrapper + f"""
{name}_body : Val(P, Str) -> Elem(P)
{name}_body = |prop| Engine.element("div", [Engine.class("c{name}")], [
        Engine.text("Leaf {name} "),
        Engine.text_v(prop.map(|p| "{k}<${{p}}>")),{kid_calls}
    ])
"""


def sparse_target(n, prefix):
    for k in range(n - 1, -1, -1):
        if k % 2 == 0 and not children(k, n):
            return f"b{prefix}{k}"


os.makedirs(OUT, exist_ok=True)
d = ["## Generated heterogeneous tree, component-boundary form.",
     "import Engine exposing [Elem, Val, Root, P, Body]", "", "Gate := [].{"]
body = []
for prefix, n in (("s", SHELL), ("a", PAGE), ("b", PAGE)):
    for k in range(n):
        body.append(component(prefix, k, n))
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
for chunk in body:
    for line in chunk.split("\n"):
        d.append(("\t" + line) if line.strip() else "")
d.append("}")
open(os.path.join(OUT, "Gate.roc"), "w").write("\n".join(d) + "\n")
print("sparse target", sparse_target(SHELL, "s"))
