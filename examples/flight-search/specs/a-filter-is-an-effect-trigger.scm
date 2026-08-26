(test "Flight search — a filter is an effect trigger"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (mark-metrics)
    (select-option (label "Sort by") "duration")
    (mark-metrics)
    (select-option (label "Sort by") "departure")

    ; a filter is an effect trigger

    (select-option (label "Airline") "Qantas")
    (expect-pending-task "flight-search" 1)
    (expect-text (test-id "request-key") "Request: SYD-ADL|2026-09-01|any|any|Qantas")
    (expect-text (test-id "filters-summary") "SYD → ADL · 2026-09-01 · Any stops · Any price · Qantas")
    (expect-text (test-id "search-status") "Searching")
    (expect-text (test-id "result-summary") "Fetching flights")
    (expect-text (test-id "result-order") "Result order: none")
    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (expect-pending-task "flight-search" 0)
    (expect-text (test-id "result-summary") "Showing 2 of 4 flights.")
    (expect-text (test-id "result-order") "Result order: QF421, QF876")
    (expect-absent (test-id "flight-row-VA518"))
  )
)
