(test "Outbox — posting a note equal to the last one still sends it"
  (steps
    (fill (label "Note") "same")
    (click (role button :name "Send"))
    (fill (label "Note") "same")
    (click (role button :name "Send"))
    (expect-pending-effects 2)
    (stub-http "first" :url "/notes/same" :status 200 :body "1")
    (run-effect 1)
    (stub-http "second" :url "/notes/same" :status 200 :body "2")
    (run-effect 2)
    (expect-text (test-id "log") "same:1 | same:2")
  )
)
