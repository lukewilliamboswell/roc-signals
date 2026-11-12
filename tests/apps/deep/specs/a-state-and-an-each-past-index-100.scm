(test "Deep — a state and its rows past index 100 refresh exactly their readers"
  (steps
    ; A row's write of the rows state (index 100): the rows reader, the
    ; each's read of its list, and the one row whose item changed.
    (mark-metrics)
    (click (test-id "inc-y"))
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-metric-delta set_text 2)
    (expect-text (test-id "y") "y=1")
    (expect-text (test-id "x") "x=0")
    (expect-text (test-id "rows") "rows=1")
    ; A whole write of it: the rows reader, the list read and row y.
    (mark-metrics)
    (click (role button :name "Reset rows"))
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-text (test-id "y") "y=0")
    (expect-text (test-id "rows") "rows=0")
    ; The counters above are untouched.
    (expect-text (test-id "e") "e=0")
    (expect-text (test-id "s") "s=0")
  )
)
