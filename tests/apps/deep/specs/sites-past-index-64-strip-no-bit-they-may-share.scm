(test "Deep — an each site past index 64 keeps the bits its rows share with layers above"
  (steps
    ; The rows (index 101, bit 37) read the counter s (index 52). Past
    ; index 64 the each keeps every bit of its rows' reads, not only those
    ; below its own, so s's settle reaches them. The 6: s's reader, the
    ; derive's input and the derived value's reader, the far read (it
    ; shares the derive's bit, which the derive adds to the pass when its
    ; value changes; pruned), and both rows' reads of s.
    (mark-metrics)
    (click (role button :name "s+1"))
    (expect-metric-delta derived_calls_into_roc 6)
    (expect-metric-delta set_text 4)
    (expect-text (test-id "s") "s=1")
    (expect-text (test-id "d") "d=2")
    (expect-text (test-id "far") "far=0")
    (expect-text (test-id "seen-x") "seen=1")
    (expect-text (test-id "seen-y") "seen=1")
  )
)
