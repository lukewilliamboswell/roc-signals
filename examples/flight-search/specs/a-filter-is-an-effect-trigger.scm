(test "Flight search — a filter is an effect trigger"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (mark-metrics)
    (select-option (label "Sort by") "duration")
    (mark-metrics)
    (select-option (label "Sort by") "departure")

    ; a filter is an effect trigger

    (select-option (label "Airline") "Aurora")
    (expect-pending-task "flight-search" 1)
    (expect-text (test-id "request-key") "Request: 2026-09-01|any|any|Aurora")
    (expect-text (test-id "filters-summary") "Filters: 2026-09-01, any stops, any price, Aurora")
    (expect-text (test-id "search-status") "Search status: loading")
    (expect-text (test-id "result-summary") "Fetching flights")
    (expect-text (test-id "result-order") "Result order: none")
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (expect-pending-task "flight-search" 0)
    (expect-text (test-id "result-summary") "Showing 2 of 4 flights.")
    (expect-text (test-id "result-order") "Result order: AU101, DE440")
    (expect-absent (test-id "flight-row-BO220"))
  )
)
