(test "When each dispose"
  (steps
    ; Ui.when whose true arm is Ui.each_str must remove its rows when it flips
    ; false, including when the condition and the row list arrive by two separate
    ; derived chains recomputed in the same batch.

    (expect-visible (role region :name "When Each"))
    (expect-text (test-id "row-r1") "Row: one!")
    (expect-text (test-id "row-r3") "Row: three!")
    (expect-absent (test-id "empty"))
    (click (role button :name "Toggle"))
    (expect-visible (test-id "empty"))
    (expect-absent (test-id "row-r1"))
    (expect-absent (test-id "row-r2"))
    (expect-absent (test-id "row-r3"))
    (expect-absent (label "Note for r1"))
    (expect-absent (label "Note for r2"))
    (expect-absent (label "Note for r3"))
    (click (role button :name "Toggle"))
    (expect-text (test-id "row-r1") "Row: one!")
    (expect-absent (test-id "empty"))

    ; A second complete disposal/remount cycle returns to exactly the same
    ; retained Roc and host allocation footprint after capacities are warm.
    (mark-metrics)
    (click (role button :name "Toggle"))
    (click (role button :name "Toggle"))
    (expect-text (test-id "row-r1") "Row: one!")
    (expect-metric-delta retained_alloc_delta 0)
    (expect-metric-delta host_retained_bytes_delta 0)
  )
)
