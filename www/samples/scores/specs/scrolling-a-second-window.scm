(test "a second board draws the window selected by its own scrollbar"
  (steps
    (click (role button :name "Show scrolled scores"))
    (expect-visible (text "Scrolled Ada 30"))
    (expect-absent (text "Scrolled Di 15"))
    (scroll (label "Scrolled scores") 84 0)
    (expect-visible (text "Scrolled Di 15"))
    (expect-visible (text "Scrolled Flo 5"))
    (expect-absent (text "Scrolled Ada 30"))
    (scroll (label "Scrolled scores") 0 0)
    (expect-visible (text "Scrolled Ada 30"))))
