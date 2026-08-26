(test "Form builder — the key cross level assertion"
  (steps
    ; Given the state established by earlier scenarios
    (fill (label "Answer f1") "Ada")
    (fill (label "Answer f2") "ada@example")
    (fill (label "Answer f2") "ada@example.com")
    (click (role button :name "Submit form"))

    ; the key cross level assertion
    ; Tighten a rule in the DESIGNER and watch previously-valid PREVIEW input turn
    ; invalid, with the submittable signal flipping in the same propagation.
    (fill (label "Minimum f1") "5")
    (expect-text (test-id "preview-f1-verdict") "Must be at least 5 characters")
    (expect-attr (label "Answer f1") aria-invalid "true")
    (expect-value (label "Answer f1") "Ada")
    (expect-text (test-id "preview-status") "Preview status: 2 fields, 1 problem")
    (expect-text (test-id "submittable-state") "Form is not submittable")
    (expect-disabled (role button :name "Submit form") true)
    ; Relaxing the same rule restores validity without touching the answer.
    (fill (label "Minimum f1") "2")
    (expect-text (test-id "preview-f1-verdict") "Valid")
    (expect-text (test-id "submittable-state") "Form is submittable")
    (expect-disabled (role button :name "Submit form") false)
  )
)
