(test "Clicking a visible drawn row keeps its scrollbar in place"
  (steps
    (click (role button :name "Show scrolled list"))
    (expect-text (test-id "scrolled-status") "0:0:0")
    (click (text "3=Task 3 "))
    (expect-text (test-id "scrolled-status") "0:0:0")))
