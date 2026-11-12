(test "Handlers — a child changes its own state and runs its owner's handler, as one event"
  (steps
    (expect-text (test-id "picker") "picker=open")
    ; The picker's own state and the owner's date; not the owner's other
    ; state.
    (mark-metrics)
    (click (role button :name "Pick 3rd"))
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-metric-delta set_text 2)
    (expect-text (test-id "picker") "picker=closed")
    (expect-text (test-id "date") "date=3rd")
    (expect-text (test-id "other") "other=0")
  ))
