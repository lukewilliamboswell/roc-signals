(test "Enter releases in the document its default navigation opened"
  (steps
    (expect-text (test-id "document-key-ups") "0")
    (press (label "Next keyboard document") "Enter")
    (expect-current-location "/next-keyboard-document")
    (expect-text (test-id "keyboard-document-url") "/next-keyboard-document")
    (expect-text (test-id "document-key-ups") "1")))
