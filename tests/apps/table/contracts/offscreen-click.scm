(test "An offscreen click must be preceded by an explicit scroll"
  (steps
    (click (role button :name "Show scrolled list"))
    (click (label "Distant scrolled control"))))
