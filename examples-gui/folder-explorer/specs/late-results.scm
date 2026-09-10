(test "A canceled scan refuses its late result and the retry decides the folder"
  (steps
    (click (role button :name "Choose folder"))
    (resolve-file-choice "folder-choice" (chosen "/tmp/project"))
    (expect-pending-task "folder-list" 1)
    (click (role button :name "Cancel"))
    (expect-pending-task "folder-list" 0)
    (expect-canceled-task "folder-list" 1)
    ; The canceled request's result arrives anyway. It must be refused by the
    ; engine, counted as refused, and must not become the displayed folder.
    (mark-metrics)
    (resolve-stale-task "folder-list" "arrived after cancellation")
    (expect-metric-delta stale_task_results_ignored 1)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-text (test-id "dataset-source") "Sample workspace")
    (expect-visible (text "6 matching entries"))
    ; Retrying starts one request, and only the result of that request decides
    ; what is shown.
    (click (role button :name "Retry"))
    (expect-pending-task "folder-list" 1)
    (resolve-file-directory "folder-list" :path "/tmp/project" :entries ((file "/tmp/project/notes.txt" 12)))
    (expect-visible (text "Folder: /tmp/project"))
    (expect-visible (text "1 matching entries"))))
