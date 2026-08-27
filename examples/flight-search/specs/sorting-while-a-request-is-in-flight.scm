(test "Flight search — sorting while a request is in flight"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (mark-metrics)
    (select-option (label "Sort by") "duration")
    (mark-metrics)
    (select-option (label "Sort by") "departure")
    (select-option (label "Airline") "Qantas")
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")

    ; sorting while a request is in flight

    (select-option (label "Airline") "any")
    (expect-pending-task "flight-search" 1)
    (expect-text (test-id "search-status") "Searching")
    ; The sort changes while the filter's request is still in flight. The pending
    ; count stays at the one already-in-flight request and nothing is canceled:
    ; the sort neither issued nor superseded a request.
    (select-option (label "Sort by") "price")
    (expect-pending-task "flight-search" 1)
    (expect-canceled-task "flight-search" 0)
    (expect-text (test-id "sort-summary") "Sorted by: price")
    (expect-text (test-id "search-status") "Searching")
    (expect-text (test-id "result-summary") "Fetching flights")
    (expect-text (test-id "result-order") "Result order: none")
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (expect-pending-task "flight-search" 0)
    (expect-text (test-id "result-order") "Result order: VA518, QF876, QF421, JQ722")
  )
)
