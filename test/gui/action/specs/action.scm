(test "Then commits its changes, runs its effect after the turn, and applies the effect's action"
  (steps
    (expect-text (text "Idle") "Idle")
    (click (role button :name "Succeed"))
    (expect-text (text "Done: HOME is set") "Done: HOME is set")
    (click (role button :name "Fail"))
    (expect-text (text "Failed: boom") "Failed: boom")
    (click (role button :name "Reset"))
    (expect-text (text "Idle") "Idle")
    (click (role button :name "Succeed"))
    (expect-text (text "Done: HOME is set") "Done: HOME is set")
  )
)
