(test "Effect closures run after the event commits and settle through the task status"
  (steps
    (expect-text (text "Idle") "Idle")
    (click (role button :name "Succeed"))
    (expect-text (text "Done: HOME is set") "Done: HOME is set")
    (click (role button :name "Fail"))
    (expect-text (text "Failed: boom") "Failed: boom")
    (click (role button :name "Succeed"))
    (expect-text (text "Done: HOME is set") "Done: HOME is set")
  )
)
