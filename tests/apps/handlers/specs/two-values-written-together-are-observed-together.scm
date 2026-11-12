(test "Handlers — an inner state and an outer state written by one event are observed together below a derive of the outer one"
  (steps
    (expect-text (test-id "pair") "pair=0/0")
    ; One click writes the inner count and the outer count. One pass
    ; settles both, from the outer count's site: the derive between them
    ; follows the outer count, the inner count joins the pass at its own
    ; site, and the text and the effect site below are each evaluated
    ; once, with both new values (3 evaluations). One text, one title and
    ; one timer: a text of 1/0 or a request for it would be a pair that
    ; never held.
    (mark-metrics)
    (click (role button :name "Raise both"))
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_metadata 1)
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-metric-delta dirty_source_roots 2)
    (expect-text (test-id "pair") "pair=1/2")
    (expect-document-title "pair 1/2")
    (expect-pending-effects 2)
    (mark-metrics)
    (click (role button :name "Raise both"))
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_metadata 1)
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-metric-delta dirty_source_roots 2)
    (expect-text (test-id "pair") "pair=2/4")
    (expect-document-title "pair 2/4")
  ))
