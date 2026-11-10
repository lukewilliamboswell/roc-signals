(test "Services — two states of a component written in one turn both refresh"
  (steps
    (click (role button :name "Both"))
    (expect-text (test-id "s1") "s1=a")
    (expect-text (test-id "s2") "s2=b")
  )
)
