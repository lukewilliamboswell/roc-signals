(test "An opened document selects nothing, so no editor survives it"
  (steps
    (click (test-id "edit-task-1"))
    (fill (label "Task notes") "Text from the document being replaced.")
    (click (role button :name "Open…"))
    (click (role button :name "Discard and open"))
    (resolve-file-choice "board-open" (chosen "/tmp/project.board.json"))

    ; The replacement document reuses task-1's key with different content. No
    ; editor may carry over, so the detail panel starts empty.
    (resolve-file-read "board-read" :path "/tmp/project.board.json" :text "{\"version\":1,\"next\":2,\"planned\":[{\"key\":\"task-1\",\"title\":\"Reused key\",\"notes\":\"\",\"assignee\":\"Unassigned\",\"priority\":\"Normal\"}],\"progress\":[],\"complete\":[]}")
    (expect-text (test-id "board-path") "/tmp/project.board.json")
    (expect-text (test-id "task-detail") "Task detailsSelect a task to edit its details.")

    ; Selecting the reused key opens a fresh editor on the new document's task.
    (click (test-id "edit-task-1"))
    (expect-value (label "Task title") "Reused key")
    (expect-value (label "Task notes") "")))
