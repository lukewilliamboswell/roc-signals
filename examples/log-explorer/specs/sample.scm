(test "Log Explorer — a sample log is written by a task to a new file, and explored like a chosen one"
  (steps
    (fill (label "Entries") "0")
    (click (role button :name "Generate a sample log"))
    (expect-text (test-id "note") "Enter a number of entries from 1 to 2,000,000.")
    (expect-pending-effects 0)
    (fill (label "Entries") "3000")
    (click (role button :name "Generate a sample log"))
    (expect-text (test-id "log") "Generating a sample log of 3,000 entries…")
    (expect-pending-work "roc-signals.example/log-explorer/generate" 1)
    (run-effect 1)
    (expect-text (test-id "log") "sample-3000.log, 212 KiB")
    (expect-text (test-id "note") "")
    (run-effect 2)
    ; The sample spans the day from midnight.
    (expect-text (test-id "overview") "3,240 lines, 3,000 entries, from 2026-11-11T00:00:18.687Z to 2026-11-11T23:59:41.138Z")
    (expect-text (test-id "sources") "Busiest sources: api 1,070, cache 479, db 455, auth 316, mailer 239 (of 10)")
    ; Its incident is where the timeline peaks.
    (expect-text (test-id "timeline-peak") "Most errors in a minute: 3 errors at 2026-11-11 12:05.")
    (expect-files 1)
  )
)
