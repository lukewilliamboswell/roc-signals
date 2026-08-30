(test "Form builder — editing one field's label, fine grained"
  (steps
    ; Given the state established by earlier scenarios
    (fill (label "Answer f1") "Ada")
    (fill (label "Answer f2") "ada@example")
    (fill (label "Answer f2") "ada@example.com")
    (click (role button :name "Submit form"))
    (fill (label "Minimum f1") "5")
    (fill (label "Minimum f1") "2")

    ; editing one field's label, fine grained
    (mark-metrics)
    (fill (label "Label f1") "Given name")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 4)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-text (test-id "preview-f1-label") "Given name (required)")
    (expect-text (test-id "preview-f1-verdict") "Valid")
    (expect-text (test-id "field-f1-summary") "Required")
    ; the sibling row is untouched
    (expect-text (test-id "preview-f2-label") "Work email (required)")
    (expect-value (label "Answer f2") "ada@example.com")
    (expect-value (label "Label f2") "Work email")
    ; required is a rule too: toggling it re-derives the preview label and verdict
    (uncheck (label "Required f2"))
    (expect-text (test-id "field-f2-summary") "Optional")
    (expect-text (test-id "preview-f2-label") "Work email")
    (check (label "Required f2"))
    (expect-text (test-id "preview-f2-label") "Work email (required)")
  )
)
