(test "Supersede — states two deep in a branch inside a late branch refresh their readers"
  (steps
    (click (role button :name "Toggle late"))
    (click (role button :name "Toggle inner"))
    (expect-text (test-id "nested") "nested 0/0")
    (click (role button :name "Inc outer"))
    (expect-text (test-id "nested") "nested 1/0")
    (click (role button :name "Inc inner"))
    (expect-text (test-id "nested") "nested 1/1")
  )
)
