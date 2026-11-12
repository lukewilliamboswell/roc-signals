(test "Handlers — an event that writes a state in a branch and closes the branch settles nothing there, and runs no handler of the branch mounted in its place"
  (steps
    (expect-absent (test-id "presses"))
    ; One click writes the branch's own state and the outer state. The
    ; outer state's pass closes the branch and mounts the other one: the
    ; condition, the new branch's derive and its one reader. The closed
    ; branch's state waited for that pass and went with the branch. The
    ; walk that follows the pass finds the other branch at its place:
    ; nothing waits there, and the button now at that place is not pressed.
    (mark-metrics)
    (click (role button :name "Close"))
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-absent (role button :name "Close"))
    (expect-text (test-id "presses") "presses=0")
    (click (role button :name "Press"))
    (expect-text (test-id "presses") "presses=1")
  ))
