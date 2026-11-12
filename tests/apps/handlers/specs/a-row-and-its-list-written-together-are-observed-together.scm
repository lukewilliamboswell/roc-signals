(test "Handlers — a row's own state and the list the row is drawn from, written by one event, are observed together in the row"
  (steps
    (expect-text (test-id "y") "0/0")
    ; One click writes the row's count and the list. One pass settles
    ; both, from the list's site: the list gives the row its new item, the
    ; row's count joins the pass at its own site in the row, and the row's
    ; text and effect site are each evaluated once, with both new values
    ; (3 evaluations, with the list). One text, one title and one timer: a
    ; text of 1/0 or a request for it would be a pair that never held.
    ; The other row is not evaluated.
    (mark-metrics)
    (click (role button :name "Rate y"))
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_metadata 1)
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-text (test-id "y") "1/1")
    (expect-text (test-id "x") "0/0")
    (expect-document-title "rated y 1/1")
    (mark-metrics)
    (click (role button :name "Rate x"))
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_metadata 1)
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-text (test-id "x") "1/1")
    (expect-text (test-id "y") "1/1")
    (expect-document-title "rated x 1/1")
  ))
