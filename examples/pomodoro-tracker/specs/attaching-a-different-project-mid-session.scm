(test "Pomodoro tracker — attaching a different project mid session"
  (setup
    ; Pomodoro Tracker - restore, run, log, and rewind the clock.

    ; The saved ledger and the saved attachment are read before the first render.
    ; Deliberately messy saved text: "api" is absent, "bogus" has no value, and
    ; "gone" is not a known project. The decoder falls back to zero and ignores the
    ; rest, so "API rewrite" mounts as a project with no logged time.
    (local-storage "pomodoro:ledger" "docs=2;bogus;gone=9;triage=1")
    (local-storage "pomodoro:project" "docs")
  )
  (steps
    ; Given the state established by earlier scenarios
    (click (role button :name "Start timer"))
    (tick-interval 1000)
    (mark-metrics)
    (tick-interval 1000)

    ; attaching a different project mid session
    ; The clock keeps running; only the project it feeds changes.
    (mark-metrics)
    (click (role button :name "Attach Bug triage"))
    (expect-text (test-id "attached-project") "Attached project: Bug triage")
    (expect-text (test-id "row-total-docs") "Docs pass: 10 min today")
    (expect-text (test-id "row-total-triage") "Bug triage: 7 min today")
    (expect-text (test-id "clock-face") "Focus 2/5 min")
    (expect-interval 1000 1)
    (expect-local-storage "pomodoro:project" "triage")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta-at-most patches_emitted 3)
    (click (role button :name "Attach Docs pass"))
    (expect-text (test-id "attached-project") "Attached project: Docs pass")
    (expect-local-storage "pomodoro:project" "docs")
  )
)
