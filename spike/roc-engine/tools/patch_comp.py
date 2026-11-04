"""Replace the component section of src/Engine.roc with the non-retaining
boundary (sinks report their mask; `split` routes to two sinks)."""
import sys
p = sys.argv[1]
s = open(p).read()
a = s.index("\t## ------------------------------------------------------------------\n\t## Component boundary")
b = s.index("\tconst : a -> Val(ctx, a)")
new = open(sys.argv[2]).read()
s = s[:a] + new + s[b:]
open(p, 'w').write(s)
