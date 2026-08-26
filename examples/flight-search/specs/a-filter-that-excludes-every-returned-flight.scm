(test "Flight search — a filter that excludes every returned flight"
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
    (select-option (label "Max stops") "0")
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (select-option (label "Airline") "Aurora")
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")

    ; a filter that excludes every returned flight

    (select-option (label "Max price") "200")
    (expect-pending-task "flight-search" 1)
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (expect-pending-task "flight-search" 0)
    (expect-text (test-id "search-status") "Search status: results ready")
    (expect-text (test-id "flights-returned") "Flights returned: 4")
    (expect-text (test-id "result-summary") "0 of 4 flights match the local filters.")
    (expect-text (test-id "result-order") "Result order: none")
    (expect-text (test-id "top-result") "Top result: none")
  )
)
