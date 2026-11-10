(test "Reading List — the store's copy after any tab writes replaces the page's"
  (steps
    (answer-port 1 reply "[{\"id\":\"b1\",\"title\":\"Dune\",\"author\":\"Frank Herbert\",\"shelf\":\"WantToRead\",\"added_ms\":\"10\"}]")
    (expect-text (test-id "status") "1 book")
    ; Another tab added a book and started reading Dune.
    (emit-port "roc-signals.example/reading-list/stored" "[{\"id\":\"b1\",\"title\":\"Dune\",\"author\":\"Frank Herbert\",\"shelf\":\"Reading\",\"added_ms\":\"10\"},{\"id\":\"b3\",\"title\":\"Middlemarch\",\"author\":\"George Eliot\",\"shelf\":\"WantToRead\",\"added_ms\":\"30\"}]")
    (expect-text (test-id "status") "2 books")
    (expect-visible (role button :name "Finish Dune"))
    (expect-visible (role button :name "Start reading Middlemarch"))
    ; This tab removes Middlemarch, but the store's next copy still holds
    ; it (the write failed): the store wins.
    (click (role button :name "Remove Middlemarch"))
    (expect-text (test-id "status") "1 book")
    (expect-port-sent "roc-signals.example/reading-list/remove" 1 "{\"id\":\"b3\"}")
    (emit-port "roc-signals.example/reading-list/stored" "[{\"id\":\"b1\",\"title\":\"Dune\",\"author\":\"Frank Herbert\",\"shelf\":\"Reading\",\"added_ms\":\"10\"},{\"id\":\"b3\",\"title\":\"Middlemarch\",\"author\":\"George Eliot\",\"shelf\":\"WantToRead\",\"added_ms\":\"30\"}]")
    (expect-text (test-id "status") "2 books")
    ; When the JavaScript ends the subscription the page says so, and keeps
    ; working.
    (close-port "roc-signals.example/reading-list/stored")
    (expect-port-subscriptions "roc-signals.example/reading-list/stored" 0)
    (expect-text (test-id "note") "Changes made in other tabs no longer reach this one. Reload to see them.")
    (click (role button :name "Finish Dune"))
    (expect-port-sends "roc-signals.example/reading-list/put" 1)
  )
)
