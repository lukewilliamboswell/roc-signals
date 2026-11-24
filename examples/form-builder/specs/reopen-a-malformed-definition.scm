(test "Form builder — a corrupt save slot leaves the current form alone"
  (setup (local-storage "roc-signals.form-builder.definition" "not a definition"))
  (steps
    (fill (label "Label f1") "Current label")
    (fill (label "Answer f1") "Ada")
    (click (role button :name "Reopen saved definition"))
    (expect-text (test-id "storage-status") "The saved definition could not be read. The current form is unchanged.")
    (expect-value (label "Label f1") "Current label")
    (expect-value (label "Answer f1") "Ada")
    (expect-local-storage "roc-signals.form-builder.definition" "not a definition")
    (storage-elsewhere-removed "roc-signals.form-builder.definition")
    (click (role button :name "Reopen saved definition"))
    (expect-text (test-id "storage-status") "No saved definition is available in this browser.")
    (expect-value (label "Label f1") "Current label")))
