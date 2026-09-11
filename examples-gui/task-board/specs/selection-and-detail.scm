(scenario "selection-and-detail"
  :window "1200x820"
  ; Initial, populated, selected, focused and disabled/enabled states. Selecting
  ; another card must move the selection and re-point the detail editors at the
  ; task that is now selected.
  (steps
    (expect-count "task-" 8)
    (expect-selected (test-id "task-1") true)
    (expect-disabled (role button :name "Undo") true)
    (expect-disabled (role button :name "Add task") true)
    (snapshot "initial")
    (click (test-id "edit-task-4"))
    (wait 400)
    (expect-selected (test-id "task-4") true)
    (expect-selected (test-id "task-1") false)
    (expect-value (label "Task title") "Polish the project sidebar")
    (expect-visible (text "In progress"))
    (snapshot "task-4-selected")
    (focus (label "Task title"))
    (key "end")
    (type (label "Task title") "!")
    (wait 400)
    (expect-focused (text "Task title"))
    (expect-value (label "Task title") "Polish the project sidebar!")
    (expect-disabled (role button :name "Undo") false)
    (snapshot "edited")
    (type (label "New task title") "Ship it")
    (wait 600)
    (expect-disabled (role button :name "Add task") false)))
