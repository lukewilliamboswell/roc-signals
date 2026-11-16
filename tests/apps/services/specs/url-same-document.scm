(test "Services — url same document"
  (setup (initial-location "/url-probe/with space#old"))
  (steps
    (click (role button :name "Replace raw URL"))
    (expect-text (test-id "url-replacements") "1")
    (navigate "/url-probe/with space#new")
    (expect-current-location "/url-probe/with%20space#new")
    (expect-text (test-id "received-location") "/url-probe/with%20space#new")
    (expect-text (test-id "url-replacements") "1")
  ))
