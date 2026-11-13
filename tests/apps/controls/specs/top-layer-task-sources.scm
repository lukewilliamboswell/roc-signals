(test "Top layer — close and toggle task sources produce order independent app facts"
  (setup (initial-location "/#top-layer"))
  (steps
    (expect-text (test-id "modal-events") "0|0")
    (click (role button :name "Open modal"))
    (expect-text (test-id "modal-events") "0|1")
    (click (role button :name "Close modal"))
    (expect-shown (label "Modal") hidden)
    (expect-text (test-id "modal-events") "1|2")
    (click (role button :name "Open modal"))
    (dismiss)
    (expect-shown (label "Modal") hidden)
    (expect-text (test-id "modal-events") "2|4")))
