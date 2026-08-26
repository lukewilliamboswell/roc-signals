(test "Flight search — an empty result set from the backend"
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
    (select-option (label "Max price") "200")
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (select-option (label "Sort by") "duration")

    ; an empty result set from the backend

    (select-option (label "Departure date") "2026-09-02")
    (expect-pending-task "flight-search" 1)
    (resolve-task "flight-search" "")
    (expect-pending-task "flight-search" 0)
    (expect-text (test-id "search-status") "Search status: results ready")
    (expect-text (test-id "flights-returned") "Flights returned: 0")
    (expect-text (test-id "result-summary") "No flights returned for these filters.")
    (expect-text (test-id "result-order") "Result order: none")
  )
)
