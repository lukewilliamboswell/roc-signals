(test "An actual SVG foreignObject wrapper restores raw HTML context"
  (setup (mount-root svg "foreignObject"))
  (steps
    (expect-text (test-id "context-root") "Change namespaced attributeToggle namespace subtreeexact HTMLlocal colonprefixed HTMLextensionno namespacexforeign HTML")
    (expect-element (test-id "context-root") html "div")
    (expect-text (test-id "gradient") "")
    (expect-element (test-id "gradient") svg "linearGradient")))
