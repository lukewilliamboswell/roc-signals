(test "Worker Lab — Cancelling mid-run stops every unfinished job and keeps the answers so far"
  (steps
    (fill (label "Jobs") "20")
    (fill (label "Weight") "1")
    (click (role button :name "Start"))
    (expect-pending-effects 15)
    (run-effect 2)
    (run-effect 7)
    (expect-text (test-id "done") "2")
    ; Two finished jobs let two waiting ones in.
    (expect-pending-effects 15)
    (expect-text (test-id "job-17") "running")
    (expect-text (test-id "job-18") "waiting")
    (click (role button :name "Cancel"))
    ; Every job in flight is cancelled, in the workers too: nothing is left
    ; pending and no later answer can land.
    (expect-pending-effects 0)
    (expect-text (test-id "job-2") "done: 153 primes")
    (expect-text (test-id "job-1") "cancelled")
    (expect-text (test-id "job-17") "cancelled")
    (expect-text (test-id "job-20") "cancelled")
    (expect-text (test-id "stopped") "18")
    (expect-text (test-id "checksum") "incomplete")
    (expect-disabled (role button :name "Cancel") true)
    ; The heartbeat kept going throughout.
    (tick-interval 200)
    (expect-text (test-id "heartbeat") "1")
    ; Reset disposes the rows.
    (click (role button :name "Reset"))
    (expect-absent (test-id "job-1"))
    (expect-text (test-id "checksum") "no run")
  )
)
