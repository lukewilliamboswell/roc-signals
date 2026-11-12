(test "Deep — a derive 64 indices below a layer it reads keeps their shared bit in its reads"
  (steps
    ; The derive (index 66) shares its bit with the counter a (index 2),
    ; which its body reads as "far". A site strips its own bit from the
    ; reads it reports only below index 64; had the derive stripped it, the
    ; far read would be left stale and the settle check would fail here.
    ; The 3: a's reader, the far read, and the derived value's reader,
    ; whose bit is in the pass and which is pruned.
    (mark-metrics)
    (click (role button :name "a+1"))
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-metric-delta set_text 2)
    (expect-text (test-id "a") "a=1")
    (expect-text (test-id "far") "far=1")
    (expect-text (test-id "d") "d=0")
  )
)
