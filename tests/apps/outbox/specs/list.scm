(test "Outbox — several things sent in one turn are one post of a list, each answer arriving with the whole list"
  (steps
    (fill (label "Note") "x")
    (click (role button :name "Send both"))
    (expect-pending-effects 2)
    (stub-http "second" :url "/notes/x2" :status 200 :body "2")
    (run-effect 2)
    (stub-http "first" :url "/notes/x" :status 200 :body "1")
    (run-effect 1)
    (expect-text (test-id "log") "x+x2:2 | x+x2:1")
  )
)
