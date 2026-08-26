(test "Pomodoro tracker — resume starts a fresh block"
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

    ; resume starts a fresh block
    (click (role button :name "Resume timer"))
    (expect-text (test-id "timer-state") "Timer: running")
    (expect-text (test-id "clock-face") "Focus 0/5 min")
    (expect-interval 1000 1)
    (tick-interval 1000)
    (expect-text (test-id "clock-face") "Focus 1/5 min")
  )
)
