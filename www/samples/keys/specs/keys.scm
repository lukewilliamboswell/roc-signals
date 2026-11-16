(test "Escape restores a focused draft and declared Tab chords trap focus"
  (steps
  (fill (label "Draft") "Changed")
  (press "Escape")
  (expect-value (label "Draft") "Original")
  (expect-focused (label "Draft"))
  (press (role button :name "Last") "Tab")
  (expect-focused (role button :name "First"))
  (press "Shift+Tab")
  (expect-focused (role button :name "Last"))
  (press "Control+k")
  (expect-focused (role button :name "First"))))
