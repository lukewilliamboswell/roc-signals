(test "Supersede — a resource and a state below it in the branch a when mounts second refresh their readers"
  (steps
    (click (role button :name "Toggle late"))
    (expect-text (test-id "answers") "answers 0")
    (run-effect 1)
    (expect-text (test-id "answers") "answers 1")
    (click (role button :name "Inc below resource"))
    (expect-text (test-id "below resource") "below resource 1")
  )
)
