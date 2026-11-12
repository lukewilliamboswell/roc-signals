(test "Writes — a write of one of a group's cells after the group's reset refines it: start again, but with this"
  (steps
    (fill (label "Draft") "hello")
    (click (role button :name "Send"))
    (click (role button :name "Send"))
    (expect-text (test-id "sent") "sent=2")
    (click (role button :name "Start again, counted"))
    (expect-text (test-id "draft") "draft=")
    (expect-text (test-id "sent") "sent=2")
  ))
