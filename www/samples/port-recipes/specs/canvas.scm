(test "A gauge receives attributes; drawing stays in its custom element"
  (setup (initial-media "(prefers-reduced-motion: reduce)" true))
  (steps
    (expect-attr (test-id "gauge") "data-value" "0")
    (expect-attr (test-id "gauge") "data-animate" "false")
    (click (role button :name "Increase gauge"))
    (expect-attr (test-id "gauge") "data-value" "1")))
