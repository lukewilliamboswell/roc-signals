(test "An actual SVG mount wrapper supplies raw namespace context"
  (setup (mount-root svg "svg"))
  (steps
    (expect-text (test-id "context-root") "Change namespaced attributeToggle namespace subtreeexact HTMLlocal colonprefixed HTMLextensionno namespacexforeign HTML")
    (expect-element (test-id "context-root") svg "DIV")
    (expect-text (test-id "exact-html") "exact HTML")
    (expect-element (test-id "exact-html") html "DIV")
    (click (role button :name "Toggle namespace subtree"))
    (expect-absent (test-id "svg-group"))
    (click (role button :name "Toggle namespace subtree"))
    (expect-text (test-id "gradient") "")
    (expect-element (test-id "gradient") svg "linearGradient")))
