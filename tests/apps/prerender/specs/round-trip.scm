(test "The picture fixture's ordinary counter returns to its first frame"
  (steps
    (expect-text (test-id "count") "0")
    (expect-text (test-id "asset-looking-data") "\"app.wasm\"")
    (expect-value (label "Escaped value") "<&\"'")
    (mark-metrics)
    (click (role button :name "Increment"))
    (expect-text (test-id "count") "1")
    (click (role button :name "Decrement"))
    (expect-text (test-id "count") "0")
    (expect-metric-delta patches_emitted 2)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)))
