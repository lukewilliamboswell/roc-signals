(test "the listing chooses the rows and their order, and the window which of them are drawn"
  (steps
    (expect-text (test-id "size") "6 players")
    ; The window: three rows from the top, then the three after them.
    (expect-visible (text "Ada 30"))
    (expect-absent (text "Di 15"))
    (click (role button :name "Next three"))
    (expect-absent (text "Ada 30"))
    (expect-visible (text "Di 15"))
    (expect-visible (text "Flo 5"))
    ; Choosing who is shown also puts the window back at the top.
    (click (role button :name "Red team"))
    (expect-visible (text "Ada 30"))
    (expect-visible (text "Cy 20"))
    (expect-visible (text "Eve 10"))
    (expect-absent (text "Ben 25"))
    ; The other order of the same rows.
    (click (role button :name "Everyone"))
    (click (role button :name "Lowest first"))
    (expect-visible (text "Flo 5"))
    (expect-visible (text "Eve 10"))
    (expect-visible (text "Di 15"))
    (expect-absent (text "Cy 20"))
    ; The podium has its own query and window, and has not moved.
    (expect-text (test-id "podium") "Ada Ben Cy ")))
