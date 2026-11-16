(test "Services — adding an empty query creates a new document"
  (setup (initial-location "/url-probe/query"))
  (steps
    (click (role button :name "Replace raw URL"))
    (expect-text (test-id "url-replacements") "1")
    (navigate "/url-probe/query?#next")
    (expect-current-location "/url-probe/query#next")
    (expect-text (test-id "received-location") "/url-probe/query#next")
    (expect-text (test-id "url-replacements") "0")))
