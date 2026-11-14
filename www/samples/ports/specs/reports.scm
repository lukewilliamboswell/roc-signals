(test "Notes — one frame of revisions lists only the newest"
  (steps
    (answer-port 1 reply "[]")
    ; A frame can contain several revisions of the store.
    ; The app keeps its earlier view until that frame is delivered.
    (hold-reports)
    (emit-port "example.org/notes/changed" "\"1\"")
    (emit-port "example.org/notes/changed" "\"2\"")
    (emit-port "example.org/notes/changed" "\"3\"")
    (expect-reports-replaced 2)
    (expect-text (test-id "notes") "No notes.")
    (release-reports)
    (expect-port-call 2 "example.org/notes/list" "{\"prefix\":\"\",\"revision\":\"3\"}")
    (answer-port 2 reply "[{\"id\":\"n1\",\"title\":\"Newest\",\"saved_ms\":\"0\"}]")
    (expect-text (test-id "notes") "Newest")))
