(test "Rejected clipboard actions leave all cell sources alone"
  (setup (clipboard-denied) (max-paste-bytes 15))
  (steps
    (press (label "B2") "Shift+ArrowRight")
    (click (role button :name "Copy selection"))
    (expect-text (test-id "range-status") "Clipboard permission was denied")
    (expect-clipboard-writes 0)

    (focus (label "B2"))
    (paste-text (label "B2") "1\t2\n3")
    (expect-text (test-id "range-status") "Pasted rows must have the same number of cells")
    (expect-value (label "B2") "1200")
    (expect-value (label "C2") "1300")

    (paste-text (label "B2") "éééééééé")
    (expect-text (test-id "range-status") "Pasted text is too large to import")
    (expect-value (label "B2") "1200")

    (focus (label "H12"))
    (paste-text (label "H12") "5\t6")
    (expect-text (test-id "range-status") "Pasted cells would extend past the sheet")
    (expect-value (label "H12") "")
    (expect-value (label "A12") "Spare")))
