(test "Log Explorer — a chosen log is indexed in a worker, and the overview shows its counts"
  (setup
    (file "app.txt" "text/plain" "2026-11-11T08:00:00.120Z INFO  api: GET /orders/1 answered 200\n2026-11-11T08:00:00.300Z DEBUG db: query took 3 ms\n2026-11-11T08:00:01.004Z ERROR db: connection reset by peer\n    at Pool.acquire (pool.roc:88)\n2026-11-11T08:00:02.000Z WARN  auth: failed sign-in for user 7\n" 40))
  (steps
    (expect-text (test-id "overview") "Open a log file, or generate a sample.")
    (expect-pending-effects 0)
    (choose-files (label "Log file") "app.txt")
    (expect-text (test-id "log") "app.txt, 10 KiB")
    ; The overview's task asks the preparation: one job, which indexes the
    ; log and answers from the index.
    (expect-pending-work "roc-signals.example/log-explorer/overview" 1)
    (expect-text (test-id "overview") "Indexing the log…")
    (run-effect 1)
    (expect-text (test-id "overview") "200 lines, 160 entries, from 2026-11-11T08:00:00.120Z to 2026-11-11T08:00:02.000Z")
    (expect-text (test-id "level-info") "40")
    (expect-text (test-id "level-debug") "40")
    (expect-text (test-id "level-error") "40")
    (expect-text (test-id "level-warn") "40")
    (expect-text (test-id "level-fatal") "0")
    (expect-text (test-id "sources") "Busiest sources: db 80, api 40, auth 40 (of 3)")
    ; The page holds the file's handle and nothing of its text.
    (expect-files 1)
    (expect-pending-effects 0)
  )
)
