(scenario "follow-and-close"
  :window "800x600"
  :choose ("specs/fixtures/events.log")
  ; Open a real log through the worker, follow it past several 500 ms polls,
  ; then leave through the window's own close path while the follow is live.
  ; The Windows review recorded an access violation on exactly this exit
  ; (GUI-29); the driver reads the process exit status, so the crash is the
  ; failure here rather than anything the frame can show.
  (steps
    (click (role button :name "Open log…"))
    (wait 800)
    (expect-count "event-" 3)
    (expect-visible (text "Pause following"))
    (snapshot "following")
    (wait 4000)
    (close)))
