(test "Flight search — initial mount"
  (setup
    (stub-http "initial search" :url "/api/flights/SYD-ADL|2026-09-01|any|any|any" :status 200 :body ""))
  (steps
    ; initial mount

    (expect-visible (role heading :name "Flight Search"))
    (expect-visible (role region :name "Search filters"))
    (expect-visible (role region :name "Sort controls"))
    (expect-visible (role region :name "Results"))
    (expect-value (label "From") "SYD")
    (expect-value (label "To") "ADL")
    (expect-value (label "Departure date") "2026-09-01")
    (expect-value (label "Max stops") "any")
    (expect-value (label "Max price") "any")
    (expect-value (label "Airline") "any")
    (expect-value (label "Sort by") "price")
    (expect-text (test-id "filters-summary") "SYD → ADL · 2026-09-01 · Any stops · Any price · All airlines")
    (expect-text (test-id "request-key") "Request: SYD-ADL|2026-09-01|any|any|any")
    (expect-text (test-id "sort-summary") "Sorted by: price")
    ; The native executor settles the initial effect before the first step.
    ; The linked browser scenario covers the suspended loading state.
    (expect-text (test-id "search-status") "Results ready")
    (expect-text (test-id "result-summary") "No flights returned for these filters.")
    (expect-text (test-id "flights-returned") "0")
    (expect-text (test-id "result-order") "Result order: none")
    (expect-text (test-id "top-result") "Top result: none")
    (expect-absent (test-id "search-error"))
    (expect-cleanup "flight search cleanup" 0)
  )
)
