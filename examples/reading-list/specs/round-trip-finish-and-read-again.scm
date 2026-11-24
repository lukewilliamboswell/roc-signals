; A round trip back to the same shelves: the soak (`--soak`) repeats the
; steps after `mark-metrics` and requires them to leave nothing allocated.
; Each move and edit sends a command without waiting for an answer.
(test "Reading List — round trip: move a book and restore its shelf, edit and restore its author, then clear a draft"
  (steps
    (answer-port 1 reply "[{\"id\":\"b1\",\"title\":\"Dune\",\"author\":\"Frank Herbert\",\"shelf\":\"WantToRead\",\"added_ms\":\"1\"},{\"id\":\"b2\",\"title\":\"Piranesi\",\"author\":\"Susanna Clarke\",\"shelf\":\"Reading\",\"added_ms\":\"2\"}]")
    (expect-text (test-id "status") "2 books")
    (mark-metrics)
    (click (role button :name "Finish Piranesi"))
    (click (role button :name "Finished"))
    (click (role button :name "All"))
    (click (role button :name "Read Piranesi again"))
    (click (role button :name "Edit Piranesi"))
    (fill (label "Book author") "S. Clarke")
    (submit (label "Edit book details"))
    (expect-visible (text "S. Clarke"))
    (click (role button :name "Edit Piranesi"))
    (fill (label "Book author") "Susanna Clarke")
    (submit (label "Edit book details"))
    (expect-visible (text "Susanna Clarke"))
    (fill (label "Title") "Soak book")
    (fill (label "Title") "")
    (expect-visible (role button :name "Finish Piranesi"))
  )
)
