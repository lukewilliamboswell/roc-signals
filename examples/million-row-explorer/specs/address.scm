(test "Million-Row Explorer — the address names the database's size and can pause the feed, and a size it cannot generate is refused with a note"
  (setup (initial-location "/?orders=lots"))
  (steps
    (expect-text (test-id "size") "2,000,000 orders. Generate")
    (expect-text (test-id "note") "\"lots\" is not a number of orders this page can generate (from 1,000 to 8,000,000): showing 2,000,000.")
    (expect-pending-work "roc-signals.example/million-row-explorer/summary" 4)
    ; Each size is a link that loads the page again at that size.
    (expect-attr (role link :name "8,000,000") href "?orders=8000000")
    (navigate "/?orders=1000")
    (expect-text (test-id "size") "1,000 orders. Generate")
    (expect-text (test-id "note") "")
    (run-effect 1)
    (run-effect 2)
    (run-effect 3)
    (run-effect 4)
    (expect-text (test-id "orders") "1,000")
    ; The address can open the page with the live feed paused.
    (expect-port-subscriptions "roc-signals.example/million-row-explorer/orders" 1)
    (navigate "/?orders=1000&feed=paused")
    (expect-port-subscriptions "roc-signals.example/million-row-explorer/orders" 0)
    (expect-checked (label "Live orders") false)
  )
)
