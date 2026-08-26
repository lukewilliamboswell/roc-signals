(test "Form builder — answering the generated form"
  (steps
    ; answering the generated form
    ; One answer at a time: the submittable fan-in only flips when BOTH inputs are
    ; satisfied.
    (fill (label "Answer f1") "Ada")
    (expect-text (test-id "preview-f1-verdict") "Valid")
    (expect-no-attr (label "Answer f1") aria-invalid)
    (expect-text (test-id "preview-status") "Preview status: 2 fields, 1 problem")
    (expect-text (test-id "submittable-state") "Form is not submittable")
    (fill (label "Answer f2") "ada@example")
    (expect-text (test-id "preview-f2-verdict") "Enter a valid email address")
    (expect-text (test-id "submittable-state") "Form is not submittable")
    (fill (label "Answer f2") "ada@example.com")
    (expect-text (test-id "preview-f2-verdict") "Valid")
    (expect-text (test-id "preview-status") "Preview status: 2 fields, 0 problems")
    (expect-text (test-id "submittable-state") "Form is submittable")
    (expect-disabled (role button :name "Submit form") false)
    (click (role button :name "Submit form"))
    (expect-text (test-id "submissions-count") "Submissions: 1")
  )
)
