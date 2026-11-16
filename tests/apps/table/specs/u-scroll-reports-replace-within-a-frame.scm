(test "scroll reports retain only their newest value while reports are held"
  (steps
    (click (role button :name "Show scrolled list"))
    (hold-reports)
    (scroll (label "Scrolled todos") 20 0)
    (scroll (label "Scrolled todos") 40 0)
    (scroll (label "Scrolled todos") 60 0)
    (expect-text (test-id "scrolled-status") "0:0:0")
    (expect-reports-replaced 2)
    (release-reports)
    (expect-text (test-id "scrolled-status") "60:0:1")
    (expect-text (test-id "scrolled") "3=Task 3 4=Task 4 5=Task 5 6=Task 6 7=Task 7 ")))
