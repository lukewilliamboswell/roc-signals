(test "Notes — saving a note lists it again at the store's next revision"
  (steps
    ; Mount subscribes to the revision and lists the notes at revision 0.
    (expect-port-subscriptions "example.org/notes/changed" 1)
    (expect-port-call 1 "example.org/notes/list" "{\"prefix\":\"\",\"revision\":\"0\"}")
    (expect-text (test-id "notes") "Loading…")
    (answer-port 1 reply "[]")
    (expect-text (test-id "notes") "No notes.")
    (fill (label "Note") "milk")
    (click (role button :name "Save"))
    (expect-port-call 2 "example.org/notes/put" "{\"id\":\"n1\",\"saved_ms\":\"0\",\"title\":\"milk\"}")
    (answer-port 2 reply "null")
    ; The store's JavaScript reports the write as a new revision.
    (emit-port "example.org/notes/changed" "\"1\"")
    (expect-port-call 3 "example.org/notes/list" "{\"prefix\":\"\",\"revision\":\"1\"}")
    (answer-port 3 reply "[{\"id\":\"n1\",\"title\":\"milk\",\"saved_ms\":\"1731200000000\"}]")
    (expect-text (test-id "notes") "milk")
    ; A store that does not answer in time says so.
    (fill (label "Filter") "m")
    (answer-port 4 timeout)
    (expect-text (test-id "notes") "The store did not answer.")
  )
)
