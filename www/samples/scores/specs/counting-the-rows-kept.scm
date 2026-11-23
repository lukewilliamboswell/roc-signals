(test "the board's list counts the players its listing keeps, not the three it draws"
  (steps
    (expect-attr (test-id "board") "data-count" "6")
    ; A change of the query: the count follows the listing.
    (click (role button :name "Red team"))
    (expect-attr (test-id "board") "data-count" "3")
    ; A write of the table: a new red player is kept, so the count grows.
    (click (role button :name "Add player"))
    (expect-attr (test-id "board") "data-count" "4")
    ; A write that keeps the same players leaves the count as it was.
    (click (role button :name "Point to the first three"))
    (expect-attr (test-id "board") "data-count" "4")
    ; Removing a player the listing keeps.
    (click (role button :name "Remove Ada"))
    (expect-attr (test-id "board") "data-count" "3")
    ; Back to everyone: five of the first six and the new player.
    (click (role button :name "Everyone"))
    (expect-attr (test-id "board") "data-count" "6")))
