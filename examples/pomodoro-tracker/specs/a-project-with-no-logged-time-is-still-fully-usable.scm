(test "Pomodoro tracker — a project with no logged time is still fully usable"
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
    (mark-metrics)
    (click (role button :name "Attach Bug triage"))
    (click (role button :name "Attach Docs pass"))
    (click (role button :name "Pause timer"))
    (tick-interval-if-active 1000)
    (click (role button :name "Resume timer"))
    (tick-interval 1000)
    (click (role button :name "Reset timer"))
    (click (role button :name "Start timer"))
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (mark-metrics)
    (click (role button :name "Log block to Docs pass"))

    ; a project with no logged time is still fully usable
    (click (role button :name "Attach API rewrite"))
    (expect-text (test-id "attached-project") "Attached project: API rewrite")
    (expect-text (test-id "row-total-api") "0 min today")
    (tick-interval 1000)
    (expect-text (test-id "row-total-api") "1 min today")
    (expect-text (test-id "row-total-docs") "15 min today")
    (click (role button :name "Pause timer"))
    (expect-text (test-id "row-total-api") "0 min today")
    (expect-interval 1000 0)
  )
)
