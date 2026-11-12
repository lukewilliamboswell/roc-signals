(test "a row's own state moves with the row and goes when the row leaves the window"
  (steps
    (click (role button :name "Cheer Cy (0)"))
    (click (role button :name "Cheer Cy (1)"))
    (expect-visible (role button :name "Cheer Cy (2)"))
    ; Six points take Cy past Ben. The row moves, with its cheers.
    (click (role button :name "Point to Cy"))
    (click (role button :name "Point to Cy"))
    (click (role button :name "Point to Cy"))
    (click (role button :name "Point to Cy"))
    (click (role button :name "Point to Cy"))
    (click (role button :name "Point to Cy"))
    (expect-text (test-id "podium") "Ada Cy Ben ")
    (expect-visible (role button :name "Cheer Cy (2)"))
    ; Scrolled out of the window and back, the row is a new one: its points
    ; are the table's and are kept, its cheers were its own and are gone.
    (click (role button :name "Next three"))
    (expect-absent (text "Cy 26"))
    (click (role button :name "First three"))
    (expect-visible (text "Cy 26"))
    (expect-visible (role button :name "Cheer Cy (0)"))))
