(test "steady-state move one row within 10,000 rows allocates bytes independent of N"
  (steps
    ; Transaction scratch memory may retain capacity, so the first event after
    ; the tables grow pays that growth once. A warm-up event absorbs it; the
    ; measured event that follows must then allocate a byte volume that does
    ; not grow with the rows already at the site. The bound is one constant
    ; shared by the 1,000 and 10,000 row cases: above the constant engine
    ; scratch plus the application's own Roc list work and the native host's
    ; simulated DOM publication, and below any graph- or tree-sized engine
    ; reservation (one u64 per active record at 10,000 rows is ~240 KB).
    (click (test-id "create-10k"))
    (expect-visible (test-id "row-10000"))
    (click (test-id "move-first-to-end"))
    (mark-metrics)
    (click (test-id "move-first-to-end"))
    (expect-metric-delta-at-most host_alloc_bytes_this_event 1048576)))
