(test "Form builder — quota rejection leaves both definitions available"
  (setup
    (local-storage "roc-signals.form-builder.definition" "previous contents")
    (local-storage-full))
  (steps
    (fill (label "Label f1") "Current label")
    (click (role button :name "Save definition"))
    (expect-text (test-id "storage-status") "The browser could not save this definition.")
    (expect-value (label "Label f1") "Current label")
    (expect-local-storage "roc-signals.form-builder.definition" "previous contents")
    (expect-disabled (role button :name "Save definition") false)))
