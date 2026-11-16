(test "Formatting receives boot facts and a batch of exact timestamps"
  (setup (initial-time 1731200000000) (languages "en-AU") (time-zone "Australia/Brisbane" 600))
  (steps
    (click (role button :name "Format dates"))
    (expect-port-call 1 "example.org/recipes/format-dates" "{\"instants\":[\"1731200000000\",\"0\"],\"languages\":[\"en-AU\"],\"zone\":\"Australia/Brisbane\"}")
    (answer-port 1 reply "[\"10 Nov 2024\",\"1 Jan 1970\"]")
    (expect-text (test-id "dates-result") "10 Nov 2024 | 1 Jan 1970")))
