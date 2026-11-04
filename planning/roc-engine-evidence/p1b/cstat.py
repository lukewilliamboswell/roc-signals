import csv, sys, statistics
rows = list(csv.DictReader(open(sys.argv[1])))
cols = ["init_roc_ns", "init_apply_ns", "dispatch_roc_ns", "dispatch_apply_ns", "allocs_this_event", "host_allocs_this_event", "host_alloc_bytes_this_event", "create_element", "set_text", "set_metadata", "remove_node", "bind_event", "derived_calls_into_roc", "scopes_created", "scopes_disposed"]
by = {}
for r in rows:
    if r.get("case") == "case":
        continue
    by.setdefault(r["case"], []).append(r)
for case, rs in by.items():
    print(f"== {case} n={len(rs)}")
    for c in cols:
        if c not in rs[0]:
            continue
        vals = [float(r[c]) for r in rs if r[c] not in ("", None)]
        if not vals:
            continue
        if c.endswith("_ns"):
            print(f"  {c:30} median {statistics.median(vals)/1e6:10.3f} ms  min {min(vals)/1e6:10.3f}  max {max(vals)/1e6:10.3f}")
        else:
            print(f"  {c:30} median {statistics.median(vals):12.0f}  min {min(vals):12.0f}  max {max(vals):12.0f}")
