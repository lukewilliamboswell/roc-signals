(test "Services — a form submits without navigating, by step and by its submit button"
  (steps
    (fill (label "Note") "rush")
    (submit (role form :name "Order"))
    (expect-text (test-id "submitted") "1")
    (real-click (role button :name "Place order"))
    (expect-text (test-id "submitted") "2")
    (expect-value (label "Note") "rush")
  )
)
