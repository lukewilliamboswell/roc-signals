(test "Flight search — success"
  (steps
    ; success

    (resolve-task "flight-search" "QF421,Qantas,06:00,305,0,145;VA518,Virgin Australia,09:30,210,1,215;JQ722,Jetstar,07:15,480,0,130;QF876,Qantas,14:05,265,2,300")
    (expect-pending-task "flight-search" 0)
    (expect-text (test-id "search-status") "Results ready")
    (expect-text (test-id "result-summary") "Showing 4 of 4 flights.")
    (expect-text (test-id "flights-returned") "4")
    (expect-text (test-id "result-order") "Result order: VA518, QF876, QF421, JQ722")
    (expect-text (test-id "top-result") "Top result: VA518")
    (expect-absent (test-id "search-error"))
    (expect-text (test-id "flight-row-VA518") "09:30 → 13:05Virgin Australia · VA518 · 3h 35m1 stop$210")
    (expect-text (test-id "flight-row-JQ722") "07:15 → 09:25Jetstar · JQ722 · 2h 10mNonstop$480")
  )
)
