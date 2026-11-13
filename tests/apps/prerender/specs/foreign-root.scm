(test "An ordinary SVG-root counter keeps its mount namespace and round trip"
  (setup (mount-root svg "svg") (initial-location "/#foreign"))
  (steps
    (expect-element (test-id "foreign-frame") svg "g")
    (expect-text (test-id "foreign-count") "0")
    (mark-metrics)
    (click (role button :name "Foreign increment"))
    (expect-text (test-id "foreign-count") "1")
    (click (role button :name "Foreign decrement"))
    (expect-text (test-id "foreign-count") "0")
    (expect-metric-delta patches_emitted 2)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)))
