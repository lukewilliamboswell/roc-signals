(test "SVG labels and dynamic structure use ordinary propagation"
  (steps
    (expect-text (test-id "graph-label") "Initial")
    (expect-text (test-id "gradient") "")
    (click (role button :name "Change graph"))
    (expect-text (test-id "graph-label") "Updated")
    (expect-absent (test-id "gradient"))
    (expect-text (test-id "html-child") "HTML child")
    (click (role button :name "Change graph"))
    (expect-text (test-id "graph-label") "Initial")
    (expect-text (test-id "gradient") "")
    (expect-absent (test-id "html-child"))))
