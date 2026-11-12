(test "Deep — a write wakes a deeper layer that shares its bit, pruned, and never a shallower one"
  (steps
    ; The counter b (index 19) shares its bit with the counter e (index
    ; 83), which lies below it: b's settle refreshes its subtree with that
    ; bit, so e's reader runs once more and is pruned.
    (mark-metrics)
    (click (role button :name "b+1"))
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-metric-delta set_text 1)
    (expect-text (test-id "b") "b=1")
    (expect-text (test-id "e") "e=0")
    ; e shares the bit the other way: b lies above it, outside the subtree
    ; its settle refreshes, so b's reader does not run.
    (mark-metrics)
    (click (role button :name "e+1"))
    (expect-metric-delta derived_calls_into_roc 1)
    (expect-metric-delta set_text 1)
    (expect-text (test-id "e") "e=1")
    (expect-text (test-id "b") "b=1")
  )
)
