"""boxify.py IN OUT name... -- route each named Engine function through a top-level
Box of the function (an erased callable), so LLVM cannot inline it into callers.
`name : T` / `name = |a, b| ...` become `name_i`, plus `name_b = Box.box(Engine.name_i)`
and a thin `name = |p0, p1| (Box.unbox(Engine.name_b))(p0, p1)`."""
import sys, re
src, out, names = sys.argv[1], sys.argv[2], sys.argv[3:]
s = open(src).read()
def nargs(t):
    d = 0; i = 0; n = 1
    while i < len(t):
        c = t[i]
        if c in "([{": d += 1
        elif c in ")]}": d -= 1
        elif c == "," and d == 0: n += 1
        elif t.startswith("->", i) and d == 0: return n
        i += 1
    raise SystemExit("no arrow in " + t)
for n in names:
    m = re.search(r"^\t%s : (.*)$" % re.escape(n), s, re.M)
    if not m: raise SystemExit("no annotation for " + n)
    ty = m.group(1); k = nargs(ty)
    ps = ", ".join(f"p{i}" for i in range(k))
    s = s.replace(f"\n\t{n} : {ty}\n", f"\n\t{n}_i : {ty}\n", 1)
    s = re.sub(r"^\t%s = " % re.escape(n), f"\t{n}_i = ", s, count=1, flags=re.M)
    wrapper = (f"\n\t{n}_b : Box(({ty}))\n\t{n}_b = Box.box(Engine.{n}_i)\n\n"
               f"\t{n} : {ty}\n\t{n} = |{ps}| (Box.unbox(Engine.{n}_b))({ps})\n")
    s = s.replace(f"\n\t{n}_i : {ty}\n", wrapper + f"\n\t{n}_i : {ty}\n", 1)
open(out, "w").write(s)
