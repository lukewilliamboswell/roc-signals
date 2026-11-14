(test "Ports sample — Roc samples a save time before handing the complete note to storage"
  (setup (initial-time 10))
  (steps
    (answer-port 1 reply "[]")
    (fill (label "Note") "Draft")
    (click (role button :name "Save"))
    (expect-value (label "Note") "")
    (set-time -1)
    (run-effect 2)
    (expect-port-call 3 "example.org/notes/put" "{\"id\":\"n1\",\"saved_ms\":\"-1\",\"title\":\"Draft\"}")
    (answer-port 3 reply "{}")
    (expect-text (test-id "error") "")
  )
)
