(test "a window write and an explicit scroll meet the browser position report"
  (steps
    (click (role button :name "Show scrolled list"))
    (click (role button :name "Jump scrolled list"))
    (expect-text (test-id "scrolled-status") "120:0:1")
    (expect-text (test-id "scrolled") "6=Task 6 7=Task 7 8=Task 8 9=Task 9 10=Task 10 ")
    (expect-scrolls 1)
    (expect-scroll 1 (label "Scrolled todos") to)))
