(test "Supersede — a resource shows its begin in the turn that changes the input"
  (steps
    (expect-text (test-id "item") "ready; showing none; before none")
    (click (role button :name "Item 1"))
    (expect-text (test-id "item") "loading 1; showing none; before none")
    (expect-pending-effects 2)
    (stub-http "one" :url "/item/1" :status 200 :body "first")
    (run-effect 1)
    (expect-text (test-id "item") "ready; showing 1:first; before none")
    (expect-pending-effects 1)
    (click (role button :name "Item 2"))
    ; The new request starts at once and the previous answer stays shown;
    ; the first item's slow-answer timer was cancelled with it.
    (expect-text (test-id "item") "loading 2; showing 1:first; before none")
    (expect-pending-effects 2)
    (stub-http "two" :url "/item/2" :status 200 :body "second")
    (run-effect 3)
    ; The fold saw the previous answer.
    (expect-text (test-id "item") "ready; showing 2:second; before 1:first")
    (click (role button :name "No item"))
    (expect-pending-effects 0)
    (expect-text (test-id "item") "ready; showing 2:second; before 1:first")
  )
)
