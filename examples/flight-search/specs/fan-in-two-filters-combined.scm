(test "Flight search — fan in: two filters combined"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (mark-metrics)
    (select-option (label "Sort by") "duration")
    (mark-metrics)
    (select-option (label "Sort by") "departure")
    (select-option (label "Airline") "Aurora")
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (select-option (label "Airline") "any")
    (select-option (label "Sort by") "price")
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")

    ; fan in: two filters combined

    (select-option (label "Max stops") "0")
    (expect-pending-task "flight-search" 1)
    (expect-text (test-id "request-key") "Request: 2026-09-01|0|any|any")
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (expect-text (test-id "result-order") "Result order: AU101, CE310")
    (expect-text (test-id "result-summary") "Showing 2 of 4 flights.")
    (select-option (label "Airline") "Aurora")
    (expect-pending-task "flight-search" 1)
    (expect-text (test-id "request-key") "Request: 2026-09-01|0|any|Aurora")
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (expect-text (test-id "filters-summary") "Filters: 2026-09-01, max 0 stops, any price, Aurora")
    (expect-text (test-id "result-order") "Result order: AU101")
    (expect-text (test-id "top-result") "Top result: AU101")
    (expect-text (test-id "result-summary") "Showing 1 of 4 flights.")
    (expect-absent (test-id "flight-row-CE310"))
  )
)
