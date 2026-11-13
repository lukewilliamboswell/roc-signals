(test "Log Explorer — a file that is empty or not a log, and a lost worker, each say so in every tab"
  (setup
    (file "empty.txt" "text/plain" "")
    (file "notes.txt" "text/plain" "shopping: eggs, flour\ncall the plumber\n")
    (file "app.txt" "text/plain" "2026-11-11T08:00:00Z INFO api: started\n"))
  (steps
    (choose-files (label "Log file") "empty.txt")
    (run-effect 1)
    (expect-text (test-id "overview") "The file is empty.")
    ; No answer, no chart.
    (expect-no-attr (test-id "timeline") data-figure)
    (expect-text (test-id "timeline-peak") "")
    ; A file with no line that starts with a timestamp and a level: the
    ; preparation's error, which every task of it answers.
    (choose-files (label "Log file") "notes.txt")
    (run-effect 2)
    (expect-text (test-id "overview") "This does not look like a log: no line starts with a timestamp and a level.")
    (expect-text (test-id "level-info") "–")
    (click (role button :name "Search"))
    (run-effect 3)
    (expect-text (test-id "search-status") "This does not look like a log: no line starts with a timestamp and a level.")
    (expect-no-attr (test-id "timeline") data-figure)
    (click (role button :name "Viewer"))
    (report-size (test-id "viewer-viewport") 800 1000)
    (run-effect 4)
    (expect-text (test-id "viewer-status") "This does not look like a log: no line starts with a timestamp and a level.")
    ; A worker that crashes loses only its job: the overview's job for the
    ; same log, asked beside it, still answers.
    (choose-files (label "Log file") "app.txt")
    (lose-work 6 app_crash)
    (expect-text (test-id "viewer-status") "The worker stopped (AppCrash). Open the log again to retry.")
    (run-effect 5)
    (click (role button :name "Overview"))
    (expect-pending-effects 0)
    (expect-text (test-id "overview") "1 line, 1 entry, from 2026-11-11T08:00:00Z to 2026-11-11T08:00:00Z")
  )
)
