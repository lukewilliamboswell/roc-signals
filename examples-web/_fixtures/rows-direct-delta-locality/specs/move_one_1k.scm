(test "move one row within 1,000 rows"
  (steps
    ; Direct-parent Rows deltas must do site-index work proportional to the
    ; edit batch, not to the rows already at the site. Single-row cases run at
    ; 1,000 and 10,000 existing rows with identical expected counts: candidate
    ; rows visited, committed keys rehashed, and membership entries rewritten
    ; are exact, and host allocation count is bounded by a constant that does
    ; not grow with N. `rows_reused` is a result count, not work. Measured
    ; clicks use test ids so harness target resolution stays out of the count.
    (click (test-id "create-1k"))
    (expect-visible (test-id "row-1000"))
    (mark-metrics)
    (click (test-id "move-first-to-end"))
    (expect-visible (test-id "row-1"))
    (expect-text (test-id "count") "Rows: 1000")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 1000)
    (expect-metric-delta rows_candidate_rows_visited 0)
    (expect-metric-delta rows_index_keys_hashed 0)
    (expect-metric-delta rows_membership_entries_rewritten 0)
    (expect-metric-delta rows_render_roots_moved 1)
    (expect-metric-delta each_key_hashes 0)
    (expect-metric-delta-at-most host_allocs_this_event 768)))
