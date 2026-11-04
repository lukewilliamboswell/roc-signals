"""norec.py IN OUT name... -- keep each named Engine function out of line: LLVM never
inlines a recursive function, so `name` becomes a guard wrapper that recurses (in a
non-tail position, each argument used once, then crashes) under a condition that is never true at run
time but cannot be proven false (a U64 equal to all ones), and otherwise calls `name_i`
(the original body, inlined into the wrapper because it has one caller)."""
import sys, re
src, out, names = sys.argv[1], sys.argv[2], sys.argv[3:]
s = open(src).read()
def split_params(t):
    d = 0; i = 0; parts = []; cur = ""
    while i < len(t):
        c = t[i]
        if t.startswith("->", i) and d == 0: parts.append(cur.strip()); return parts
        if c in "([{": d += 1
        elif c in ")]}": d -= 1
        if c == "," and d == 0: parts.append(cur.strip()); cur = ""
        else: cur += c
        i += 1
    raise SystemExit("no arrow")
GUARD = {"U64": "{p}", "U32": "{p}.to_u64()", "U8": "{p}.to_u64()", "Tx": "{p}.evals", "EachCore": "{p}.depth", "Core": "{p}.reads", "Walk": "{p}.pos", "List(Op)": "{p}.len()", "List(U8)": "{p}.len()", "List(Str)": "{p}.len()", "List(U64)": "{p}.len()"}
for n in names:
    m = re.search(r"^\t%s : (.*)\n((?:\t\twhere.*\n)?)" % re.escape(n), s, re.M)
    if not m: raise SystemExit("no annotation for " + n)
    ty = m.group(1); where = m.group(2); ps = split_params(ty)
    g = None
    for pref in ["U64", "U32", "U8", "Tx", "EachCore", "Core", "Walk", "List(Op)", "List(U8)", "List(Str)", "List(U64)"]:
        if pref in ps: g = GUARD[pref].format(p=f"p{ps.index(pref)}"); break
    if g is None: raise SystemExit("no guard param for " + n)
    args = ", ".join(f"p{i}" for i in range(len(ps)))
    s = s.replace(f"\n\t{n} : {ty}\n{where}", f"\n\t{n}_i : {ty}\n{where}", 1)
    s = re.sub(r"^\t%s = " % re.escape(n), f"\t{n}_i = ", s, count=1, flags=re.M)
    wrapper = (f"\n\t{n} : {ty}\n{where}\t{n} = |{args}| if Engine.never({g}) {{\n\t\t_ = Engine.{n}({args})\n\t\tcrash \"never\"\n\t}} else Engine.{n}_i({args})\n")
    s = s.replace(f"\n\t{n}_i : {ty}\n{where}", wrapper + f"\n\t{n}_i : {ty}\n{where}", 1)
s = s.replace("\n\tread_of : ", "\n\t## Never true at run time; LLVM cannot prove it (see norec.py).\n\tnever : U64 -> Bool\n\tnever = |x| x == 18446744073709551615\n\n\tread_of : ", 1)
open(out, "w").write(s)
