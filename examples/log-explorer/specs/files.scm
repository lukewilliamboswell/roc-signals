(test "Log Explorer — every tab asks the same prepared log, a new file is asked afresh, and closing it lets it go"
  (setup
    (file "app.txt" "text/plain" "2026-11-11T08:00:00.120Z INFO  api: GET /orders/1 answered 200\n2026-11-11T08:00:01.004Z ERROR db: connection reset by peer\n    at Pool.acquire (pool.roc:88)\n" 10)
    (file "other.txt" "text/plain" "2026-11-12T09:30:00Z [warn] [cache] miss for user:7\n" 3))
  (steps
    (choose-files (label "Log file") "app.txt")
    (run-effect 1)
    (expect-text (test-id "overview") "30 lines, 20 entries, from 2026-11-11T08:00:00.120Z to 2026-11-11T08:00:01.004Z")
    (click (role button :name "Search"))
    (run-effect 2)
    (expect-text (test-id "search-status") "30 matching lines, page 1 of 2.")
    ; A second search, a second question of the same preparation.
    (fill (label "Text to find") "pool")
    (run-effect 3)
    (expect-text (test-id "search-status") "10 matching lines, page 1 of 1.")
    ; The overview was asked once for the log, above the tabs: going back
    ; to it asks nothing.
    (click (role button :name "Overview"))
    (expect-pending-effects 0)
    (expect-text (test-id "overview") "30 lines, 20 entries, from 2026-11-11T08:00:00.120Z to 2026-11-11T08:00:01.004Z")
    ; A revisited search asks its task again.
    (click (role button :name "Search"))
    (expect-pending-work "roc-signals.example/log-explorer/search" 1)
    (run-effect 4)
    (expect-text (test-id "search-status") "10 matching lines, page 1 of 1.")
    (click (role button :name "Overview"))
    ; Another file: its own answers, and the first file is let go.
    (choose-files (label "Log file") "other.txt")
    (expect-text (test-id "log") "other.txt, 156 bytes")
    (expect-pending-work "roc-signals.example/log-explorer/overview" 1)
    (run-effect 5)
    (expect-text (test-id "overview") "3 lines, 3 entries, from 2026-11-12T09:30:00Z to 2026-11-12T09:30:00Z")
    (expect-text (test-id "level-warn") "3")
    (expect-text (test-id "sources") "Busiest sources: cache 3 (of 1)")
    (expect-files 1)
    (click (role button :name "Close the log"))
    (expect-files 0)
    (expect-text (test-id "overview") "Open a log file, or generate a sample.")
    (expect-pending-effects 0)
  )
)
