(test "Flight search — fan in: two filters combined"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (mark-metrics)
    (select-option (label "Sort by") "duration")
    (mark-metrics)
    (select-option (label "Sort by") "departure")
    (select-option (label "Airline") "Qantas")
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (select-option (label "Airline") "any")
    (select-option (label "Sort by") "price")
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")

    ; fan in: two filters combined

    (select-option (label "Max stops") "0")
    (expect-pending-task "flight-search" 1)
    (expect-text (test-id "request-key") "Request: SYD-ADL|2026-09-01|0|any|any")
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (expect-text (test-id "result-order") "Result order: QF421, JQ722")
    (expect-text (test-id "result-summary") "Showing 2 of 4 flights.")
    (select-option (label "Airline") "Qantas")
    (expect-pending-task "flight-search" 1)
    (expect-text (test-id "request-key") "Request: SYD-ADL|2026-09-01|0|any|Qantas")
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (expect-text (test-id "filters-summary") "SYD → ADL · 2026-09-01 · Nonstop only · Any price · Qantas")
    (expect-text (test-id "result-order") "Result order: QF421")
    (expect-text (test-id "top-result") "Top result: QF421")
    (expect-text (test-id "result-summary") "Showing 1 of 4 flights.")
    (expect-absent (test-id "flight-row-JQ722"))
  )
)
