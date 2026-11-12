(test "Supersede — a state in the branch a when mounts second refreshes its readers"
  (steps
    (click (role button :name "Toggle solo"))
    (expect-text (test-id "late") "late 0")
    (click (role button :name "Inc late"))
    (expect-text (test-id "late") "late 1")
    (expect-document-title "late 1")
    (click (role button :name "Inc late"))
    (expect-text (test-id "late") "late 2")
    (expect-document-title "late 2")
  )
)
