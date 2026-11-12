; A round trip back to the same shelves: the soak (`--soak`) repeats the
; steps after `mark-metrics` and requires them to leave nothing allocated.
; Each move sends a command; none waits for an answer.
(test "Reading List — round trip: a book finished and read again, the finished shelf shown and left, a title typed and cleared"
  (steps
    (answer-port 1 reply "[{\"id\":\"b1\",\"title\":\"Dune\",\"author\":\"Frank Herbert\",\"shelf\":\"WantToRead\",\"added_ms\":\"1\"},{\"id\":\"b2\",\"title\":\"Piranesi\",\"author\":\"Susanna Clarke\",\"shelf\":\"Reading\",\"added_ms\":\"2\"}]")
    (expect-text (test-id "status") "2 books")
    (mark-metrics)
    (click (role button :name "Finish Piranesi"))
    (click (role button :name "Finished"))
    (click (role button :name "All"))
    (click (role button :name "Read Piranesi again"))
    (fill (label "Title") "Soak book")
    (fill (label "Title") "")
    (expect-visible (role button :name "Finish Piranesi"))
  )
)
