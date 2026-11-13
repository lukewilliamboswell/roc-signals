(test "Services — retaining an empty query keeps the current document"
  (setup (initial-location "/url-probe/query?"))
  (steps
    (click (role button :name "Replace raw URL"))
    (expect-text (test-id "url-replacements") "1")
    (navigate "/url-probe/query?#next")
    (expect-current-location "/url-probe/query#next")
    (expect-text (test-id "received-location") "/url-probe/query#next")
    (expect-text (test-id "url-replacements") "1")
    (click (role link :name "Follow raw fragment"))
    (expect-text (test-id "url-replacements") "1")
    (expect-current-location "/url-probe/query#l=caf%C3%A9%20au%20lait%22%3C%3E%60{}'?#")
    (expect-text (test-id "received-location") "/url-probe/query#l=caf%C3%A9%20au%20lait%22%3C%3E%60{}'?#")))
