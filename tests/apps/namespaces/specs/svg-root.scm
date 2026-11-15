(test "An actual SVG mount wrapper supplies raw namespace context"
  (setup (mount-root svg "svg"))
  (steps
    (expect-element (test-id "svg-group") svg "g")
    (expect-text (test-id "context-root") "Change namespaced attributeToggle namespace subtreeexact HTMLlocal colonprefixed HTMLextensionno namespacexforeign HTML")
    (expect-element (test-id "context-root") svg "DIV")
    (expect-text (test-id "exact-html") "exact HTML")
    (expect-element (test-id "exact-html") html "DIV")
    ; Under an SVG root the browser draws none of the app's HTML, so the
    ; subtree is toggled by the location rather than by a click.
    (navigate "/#hidden")
    (expect-absent (test-id "svg-group"))
    (navigate "/#shown")
    (expect-element (test-id "svg-group") svg "g")
    (expect-text (test-id "gradient") "")
    (expect-element (test-id "gradient") svg "linearGradient")))
