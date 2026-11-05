(test "Services — a page booted hidden starts without the poll interval"
  (setup
    (initial-visibility hidden))
  (steps
    (expect-text (test-id "visible") "hidden")
    (expect-interval 5000 0)
    (set-visibility visible)
    (expect-interval 5000 1)
  )
)
