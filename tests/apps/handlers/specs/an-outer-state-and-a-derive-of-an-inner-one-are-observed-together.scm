(test "Handlers — an outer state and an inner state written by one event are observed together below a derive of the inner one"
  (steps
    (expect-text (test-id "mixed") "mixed=0/0")
    ; One click writes the inner count and the outer count above it. One
    ; pass settles both, from the outer count's site: the inner count
    ; joins it at its own site, the derive of the inner count follows, and
    ; the text and the effect site below are each evaluated once, with
    ; the outer count and the derived value both new (3 evaluations). One
    ; text, one title and one timer, for the pair that holds: a text of
    ; 1/0, the new outer count beside the old derived value, or a request
    ; for it, would be a pair that never held. A state beside the inner
    ; count, at the same depth, has a reader of its own, which is not
    ; evaluated: the inner count is carried below its own site only.
    (mark-metrics)
    (click (role button :name "Raise outer and inner"))
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_metadata 1)
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-metric-delta dirty_source_roots 2)
    (expect-updates (test-id "mixed") 2)
    (expect-text (test-id "mixed") "mixed=1/2")
    (expect-updates (test-id "aside") 1)
    (expect-document-title "mixed 1/2")
    (mark-metrics)
    (click (role button :name "Raise outer and inner"))
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_metadata 1)
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-updates (test-id "mixed") 3)
    (expect-text (test-id "mixed") "mixed=2/4")
    (expect-document-title "mixed 2/4")
  ))
