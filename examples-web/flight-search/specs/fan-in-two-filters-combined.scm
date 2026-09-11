(test "Flight search — fan in: two filters combined"
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

    ; fan in: two filters combined

    (stub-http "search" :url "/api/flights/SYD-ADL|2026-09-01|0|any|any" :status 200 :body "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (select-option (label "Max stops") "0")
    (expect-text (test-id "request-key") "Request: SYD-ADL|2026-09-01|0|any|any")
    (expect-text (test-id "result-order") "Result order: QF421, JQ722")
    (expect-text (test-id "result-summary") "Showing 2 of 4 flights.")
    (stub-http "search" :url "/api/flights/SYD-ADL|2026-09-01|0|any|Qantas" :status 200 :body "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (select-option (label "Airline") "Qantas")
    (expect-text (test-id "request-key") "Request: SYD-ADL|2026-09-01|0|any|Qantas")
    (expect-text (test-id "filters-summary") "SYD → ADL · 2026-09-01 · Nonstop only · Any price · Qantas")
    (expect-text (test-id "result-order") "Result order: QF421")
    (expect-text (test-id "top-result") "Top result: QF421")
    (expect-text (test-id "result-summary") "Showing 1 of 4 flights.")
    (expect-absent (test-id "flight-row-JQ722"))
  )
)
