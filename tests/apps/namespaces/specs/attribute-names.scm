(test "Attribute steps read an exact local name in no namespace in both runners"
  (steps
    ; An uppercase name is its own attribute, never the lowercase one.
    (expect-attr (test-id "exact-value") "VALUE" "exact attribute")
    ; A raw colon name is not the XLink-namespaced href beside it.
    (expect-attr (test-id "svg-group") "xlink:href" "raw")
    (click (role button :name "Change namespaced attribute"))
    (expect-attr (test-id "svg-group") "xlink:href" "raw")))
