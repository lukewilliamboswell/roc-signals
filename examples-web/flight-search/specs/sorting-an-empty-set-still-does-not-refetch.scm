(test "Flight search — sorting an empty set still does not refetch"
  (setup
    (stub-http "search" :url "/api/flights/SYD-ADL|2026-09-01|any|any|any" :status 200 :body "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300"))
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (select-option (label "Sort by") "duration")
    (mark-metrics)
    (select-option (label "Sort by") "departure")
    (stub-http "search" :url "/api/flights/SYD-ADL|2026-09-01|any|any|Qantas" :status 200 :body "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (select-option (label "Airline") "Qantas")
    (stub-http "search" :url "/api/flights/SYD-ADL|2026-09-01|any|any|any" :status 200 :body "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (select-option (label "Airline") "any")
    (select-option (label "Sort by") "price")
    (stub-http "search" :url "/api/flights/SYD-ADL|2026-09-01|0|any|any" :status 200 :body "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (select-option (label "Max stops") "0")
    (stub-http "search" :url "/api/flights/SYD-ADL|2026-09-01|0|any|Qantas" :status 200 :body "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (select-option (label "Airline") "Qantas")
    (stub-http "search" :url "/api/flights/SYD-ADL|2026-09-01|0|200|Qantas" :status 200 :body "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (select-option (label "Max price") "200")

    ; sorting an empty set still does not refetch

    (select-option (label "Sort by") "duration")
    (expect-text (test-id "sort-summary") "Sorted by: duration")
    (expect-text (test-id "result-order") "Result order: none")
    (expect-text (test-id "result-summary") "0 of 4 flights match the local filters.")
  )
)
