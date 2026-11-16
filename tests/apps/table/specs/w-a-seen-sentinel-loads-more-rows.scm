(test "an ahead sentinel admits the next fixed-height page"
  (steps
    (click (role button :name "Show scrolled list"))
    (expect-observed 1)
    (report-seen (label "Load more scrolled") yes)
    (scroll (label "Scrolled todos") 3000 0)
    (expect-text (test-id "scrolled") "150=Task 150 151=Task 151 152=Task 152 153=Task 153 154=Task 154 ")
    (click (role button :name "Hide scrolled list"))
    (expect-observed 0)))
