(test "Flight search — success"
  (steps
    ; success

    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")
    (expect-pending-task "flight-search" 0)
    (expect-text (test-id "search-status") "Search status: results ready")
    (expect-text (test-id "result-summary") "Showing 4 of 4 flights.")
    (expect-text (test-id "flights-returned") "Flights returned: 4")
    (expect-text (test-id "result-order") "Result order: BO220, DE440, AU101, CE310")
    (expect-text (test-id "top-result") "Top result: BO220")
    (expect-text (test-id "search-error") "No search error")
    (expect-text (test-id "flight-row-BO220") "BO220 - Borealis - departs 09:30 - $210 - 1 stops - 215 min")
    (expect-text (test-id "flight-row-CE310") "CE310 - Cirrus - departs 07:15 - $480 - 0 stops - 130 min")
  )
)
