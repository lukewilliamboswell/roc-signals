(test "Pomodoro tracker — pause voids the block in progress"
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

    ; pause voids the block in progress
    (click (role button :name "Pause timer"))
    (expect-text (test-id "timer-state") "Timer: paused")
    (expect-text (test-id "clock-face") "Focus 0/5 min")
    (expect-text (test-id "row-total-docs") "Docs pass: 10 min today")
    (expect-text (test-id "focus-minutes") "Focus minutes today: 15")
    (expect-interval 1000 0)
    (expect-cleanup "pomodoro clock cleanup" 1)
    (tick-interval-if-active 1000)
    (expect-text (test-id "clock-face") "Focus 0/5 min")
  )
)
