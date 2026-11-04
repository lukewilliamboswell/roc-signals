"""libify.py IN OUT name... -- move each named Engine function (which must take a Tx
parameter) behind an erased callable created once in `new_tx` and carried in Tx.lib:
`name_i` holds the body; `name` becomes a thin wrapper `(Box.unbox(tx.lib.name))(...)`.
LLVM cannot inline through the erased call, so the body exists once."""
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
# Tx gains a lib field everywhere it is built or destructured.
s = s.replace("\tTx : {", "\tTx := {", 1)
s = s.replace("\t\tsite_free : List(U32),\n\t}", "\t\tsite_free : List(U32),\n\t\tlib : Lib,\n\t}", 1)
s = s.replace("paths, site_free }", "paths, site_free, lib }")
s = s.replace("site_free: site_free.drop_last(1) }", "site_free: site_free.drop_last(1), lib }")
s = s.replace("paths.append(path), site_free })", "paths.append(path), site_free, lib })")
s = s.replace("site_free: site_free.append(s) }", "site_free: site_free.append(s), lib }")
s = s.replace("paths: [[]], site_free: [] }", "paths: [[]], site_free: [], lib: Engine.lib_new({}) }")
fields = []; inits = []
for n in names:
    m = re.search(r"^\t%s : (.*)$" % re.escape(n), s, re.M)
    if not m: raise SystemExit("no annotation for " + n)
    ty = m.group(1); ps = split_params(ty)
    if "Tx" not in ps: raise SystemExit(n + " has no Tx param")
    ti = ps.index("Tx")
    names_p = [f"p{i}" for i in range(len(ps))]
    s = s.replace(f"\n\t{n} : {ty}\n", f"\n\t{n}_i : {ty}\n", 1)
    s = re.sub(r"^\t%s = " % re.escape(n), f"\t{n}_i = ", s, count=1, flags=re.M)
    wrapper = f"\n\t{n} : {ty}\n\t{n} = |{', '.join(names_p)}| (Box.unbox(p{ti}.lib.{n}))({', '.join(names_p)})\n"
    s = s.replace(f"\n\t{n}_i : {ty}\n", wrapper + f"\n\t{n}_i : {ty}\n", 1)
    fields.append(f"\t\t{n} : Box(({ty})),")
    inits.append(f"\t\t{n}: Box.box(Engine.{n}_i),")
lib = ("\n\t## Erased monomorphic routines, boxed once per app (see libify.py).\n\tLib := {\n" + "\n".join(fields) + "\n\t}\n\n"
       "\tlib_new : {} -> Lib\n\tlib_new = |_| {\n" + "\n".join(inits) + "\n\t}\n")
s = s.replace("\n\tread_of : ", lib + "\n\tread_of : ", 1)
open(out, "w").write(s)
