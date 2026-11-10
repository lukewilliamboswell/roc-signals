(test "Log Explorer — a file that is empty or not a log, and a lost worker, each say so in every tab"
  (setup
    (file "empty.log" "text/x-log" "")
    (file "notes.txt" "text/plain" "shopping: eggs, flour\ncall the plumber\n")
    (file "app.log" "text/x-log" "2026-11-11T08:00:00Z INFO api: started\n"))
  (steps
    (choose-files (label "Log file") "empty.log")
    (run-effect 1)
    (expect-text (test-id "overview") "The file is empty.")
    ; A file with no line that starts with a timestamp and a level: the
    ; preparation's error, which every task of it answers.
    (choose-files (label "Log file") "notes.txt")
    (run-effect 2)
    (expect-text (test-id "overview") "This does not look like a log: no line starts with a timestamp and a level.")
    (expect-text (test-id "level-info") "–")
    (click (role button :name "Search"))
    (run-effect 3)
    (expect-text (test-id "search-status") "This does not look like a log: no line starts with a timestamp and a level.")
    (click (role button :name "Viewer"))
    (run-effect 4)
    (expect-text (test-id "viewer-status") "This does not look like a log: no line starts with a timestamp and a level.")
    ; A worker that crashes loses only its job.
    (choose-files (label "Log file") "app.log")
    (lose-work 5 app_crash)
    (expect-text (test-id "viewer-status") "The worker stopped (AppCrash). Open the log again to retry.")
    (click (role button :name "Overview"))
    (run-effect 6)
    (expect-text (test-id "overview") "1 line, 1 entry, from 2026-11-11T08:00:00Z to 2026-11-11T08:00:00Z")
  )
)
