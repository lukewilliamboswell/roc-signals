(test "Supersede — a state below a derive or a resource mounted with the page refreshes its readers"
  (steps
    (click (role button :name "Inc early derived"))
    (expect-text (test-id "early derived") "early derived 1")
    (click (role button :name "Inc early resource"))
    (expect-text (test-id "early resource") "early resource 1")
  )
)
