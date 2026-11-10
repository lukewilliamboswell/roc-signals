(test "Supersede — a plan of no requests makes a change a pure cancel"
  (steps
    (click (role button :name "Search A"))
    (expect-pending-effects 1)
    (click (role button :name "Clear"))
    (expect-pending-effects 0)
    (click (role button :name "Search B"))
    (stub-http "b" :url "/search?q=b" :status 200 :body "beta")
    (run-effect 2)
    (expect-text (test-id "results") "b:beta")
  )
)
