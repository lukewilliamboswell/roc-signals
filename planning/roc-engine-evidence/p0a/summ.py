import json, sys
d = json.load(open(sys.argv[1]))
if "examples" in d:
    exs = d["examples"]
else:
    exs = [ex for e in d["entries"] for ex in e["examples"]]
for ex in exs:
    if "outcome" in ex:
        print(f'== {ex["name"]}: {ex["outcome"]} {ex.get("finding_kind")} trace_ok={ex.get("trace_rules_passed")}')
    for o in (ex.get("observations") or []):
        s = o["stats"]
        if o["name"] == "step":
            continue
        print(f'{ex["name"]:24} {o["name"]:28} allocs={s["allocs"]:>8} reallocs={s["reallocs"]:>4} deallocs={s["deallocs"]:>8} bytes={s["requested_bytes"]:>12} peak={s["peak_live_bytes"]:>12}')
