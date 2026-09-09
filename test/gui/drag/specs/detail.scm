(test "Native drop routes its typed detail through ordinary state propagation"
  (steps
    (expect-visible (text "Dropped: none"))
    (custom-event (test-id "drop-target") "drop" "task-λ")
    (expect-visible (text "Dropped: task-λ"))))
