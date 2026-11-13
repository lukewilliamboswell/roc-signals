(test "Pasting text on a reachable element without a paste listener does nothing"
  (setup (initial-location "/#persistence"))
  (steps
    (paste-text (role "button" :name "Guard on") "ignored")
    (expect-text (test-id "pasted") "")
    (expect-current-location "/#persistence")))
