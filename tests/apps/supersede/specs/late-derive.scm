(test "Supersede — a state below a derive in the branch a when mounts second refreshes its readers"
  (steps
    (click (role button :name "Toggle late"))
    (click (role button :name "Inc derived"))
    (expect-text (test-id "derived") "derived 1")
  )
)
