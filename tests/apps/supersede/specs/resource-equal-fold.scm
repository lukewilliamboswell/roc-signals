(test "Supersede — an equal fold does no work below the layer"
  (steps
    (click (role button :name "Item 1"))
    (stub-http "one" :url "/item/1" :status 200 :body "first")
    (run-effect 1)
    (mark-metrics)
    ; The slow-answer timer fires after the answer: the fold returns the
    ; layer unchanged, so nothing reads it again.
    (run-effect 2)
    (expect-metric-delta dirty_source_roots 0)
    (expect-metric-delta derived_calls_into_roc 0)
    (expect-metric-delta patches_emitted 0)
    (click (role button :name "Item 2"))
    (mark-metrics)
    ; Before the answer the same timer marks the request slow: one layer
    ; written, one text.
    (run-effect 4)
    (expect-text (test-id "item") "loading 2 (slow); showing 1:first; before none")
    (expect-metric-delta dirty_source_roots 1)
    (expect-metric-delta set_text 1)
    (expect-metric-delta patches_emitted 1)
  )
)
