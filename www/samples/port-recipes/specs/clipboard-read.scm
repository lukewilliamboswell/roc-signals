(test "Clipboard text crosses only as the call answer"
  (steps
    (click (role button :name "Read clipboard"))
    (expect-port-call 1 "example.org/recipes/clipboard-read" "{}")
    (answer-port 1 reply "\"Text from the reader\"")
    (expect-text (test-id "clipboard-result") "Text from the reader")
    (click (role button :name "Read clipboard"))
    (answer-port 2 throw "Permission denied")
    (expect-text (test-id "clipboard-result") "Unavailable: Threw(\"Permission denied\")")))
