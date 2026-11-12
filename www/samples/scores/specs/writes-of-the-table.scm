(test "rows are added, written several at once, rewritten whole and started again"
  (steps
    ; A new player takes the next key. With no points it is last, outside
    ; the window, so the board draws nothing new.
    (mark-metrics)
    (click (role button :name "Add player"))
    (expect-text (test-id "size") "7 players")
    (expect-metric-delta rows_created 0)
    (click (role button :name "Lowest first"))
    (expect-visible (text "Player 7 0"))
    (click (role button :name "Add player"))
    (expect-text (test-id "size") "8 players")
    (expect-visible (text "Player 8 0"))
    ; Three keyed writes in one event.
    (click (role button :name "Point to the first three"))
    (expect-text (test-id "podium") "Ada Ben Cy ")
    (click (role button :name "Next three"))
    (expect-visible (text "Di 15"))
    (expect-visible (text "Cy 21"))
    ; A row removed from the table leaves every view of it.
    (click (role button :name "Remove Cy"))
    (expect-text (test-id "size") "7 players")
    (expect-text (test-id "podium") "Ada Ben Di ")
    (expect-absent (text "Cy 21"))
    ; A whole rewrite: every row changes, and each view builds itself again.
    (click (role button :name "Clear the points"))
    (click (role button :name "First three"))
    (expect-visible (text "Ada 0"))
    (expect-text (test-id "podium") "Ada Ben Di ")
    ; The generated reset puts the table and the next key back as described.
    (click (role button :name "New season"))
    (expect-text (test-id "size") "6 players")
    (expect-text (test-id "podium") "Ada Ben Cy ")
    (expect-visible (text "Flo 5"))
    (click (role button :name "Add player"))
    (expect-visible (text "Player 7 0"))))
