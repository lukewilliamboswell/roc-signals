(test "Reading List — a store that does not answer, answers what the app does not understand, or refuses a book"
  (setup (seed 7) (initial-time 1731200000000))
  (steps
    (answer-port 1 timeout)
    (expect-text (test-id "status") "Your shelf could not be read: the store did not answer in time.")
    (expect-disabled (role button :name "Add book") true)
    ; A new document asks again: the books live in the store, not the page.
    (navigate "/?again")
    (expect-text (test-id "status") "Opening your shelf…")
    (expect-port-call 1 "roc-signals.example/reading-list/load" "{}")
    (answer-port 1 reply "[{\"id\":\"b1\",\"title\":\"Dune\",\"author\":\"\",\"shelf\":\"Abandoned\",\"added_ms\":\"10\"}]")
    (expect-text (test-id "status") "Your shelf could not be read: it holds something this app does not understand (port \"roc-signals.example/reading-list/load\": unknown tag \"Abandoned\").")
    ; The list keys its rows by id, so a shelf with two books under one id is
    ; refused where it arrives.
    (navigate "/?twice")
    (answer-port 1 reply "[{\"id\":\"b1\",\"title\":\"Dune\",\"author\":\"\",\"shelf\":\"Reading\",\"added_ms\":\"10\"},{\"id\":\"b1\",\"title\":\"Piranesi\",\"author\":\"\",\"shelf\":\"Reading\",\"added_ms\":\"20\"}]")
    (expect-text (test-id "status") "Your shelf could not be read: it holds two books under one id.")
    (navigate "/?third")
    (answer-port 1 reply "[]")
    (fill (label "Title") "Piranesi")
    (click (role button :name "Add book"))
    (run-effect 2)
    (expect-port-call 3 "roc-signals.example/reading-list/add" "{\"added_ms\":\"1731200000000\",\"author\":\"\",\"id\":\"b-088712be8a582fca\",\"shelf\":\"WantToRead\",\"title\":\"Piranesi\"}")
    (answer-port 3 throw "QuotaExceededError")
    (expect-text (test-id "note") "\"Piranesi\" was not added: the store said \"QuotaExceededError\".")
    (expect-text (test-id "status") "No books yet. Add the first one above.")
  )
)
