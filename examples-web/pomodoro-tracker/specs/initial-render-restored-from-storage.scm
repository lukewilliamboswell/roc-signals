(test "Pomodoro tracker — initial render, restored from storage"
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
    ; initial render, restored from storage
    (expect-visible (role heading :name "Pomodoro Tracker"))
    (expect-visible (role region :name "Timer"))
    (expect-visible (role region :name "Projects"))
    (expect-visible (role region :name "Today"))
    (expect-visible (role region :name "API rewrite"))
    (expect-visible (role region :name "Docs pass"))
    (expect-visible (role region :name "Bug triage"))
    (expect-text (test-id "timer-state") "Timer: idle")
    (expect-text (test-id "clock-face") "Focus 0/5 min")
    (expect-text (test-id "attached-project") "Attached project: Docs pass")
    (expect-text (test-id "row-total-api") "0 min today")
    (expect-text (test-id "row-total-docs") "10 min today")
    (expect-text (test-id "row-total-triage") "5 min today")
    (expect-text (test-id "blocks-logged") "3")
    (expect-text (test-id "focus-minutes") "15")
    (expect-disabled (role button :name "Reset timer") true)
    (expect-disabled (role button :name "Log block to Docs pass") true)
    (expect-interval 1000 0)
    (expect-cleanup "pomodoro clock cleanup" 0)
  )
)
