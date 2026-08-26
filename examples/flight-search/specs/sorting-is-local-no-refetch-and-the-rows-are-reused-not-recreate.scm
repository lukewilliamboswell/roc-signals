(test "Flight search — sorting is local: no refetch, and the rows are reused not recreated"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "flight-search" "AU101,Aurora,06:00,305,0,145;BO220,Borealis,09:30,210,1,215;CE310,Cirrus,07:15,480,0,130;DE440,Aurora,14:05,265,2,300")

    ; sorting is local: no refetch, and the rows are reused not recreated

    (mark-metrics)
    (select-option (label "Sort by") "duration")
    (expect-pending-task "flight-search" 0)
    (expect-text (test-id "sort-summary") "Sorted by: duration")
    (expect-text (test-id "result-order") "Result order: CE310, AU101, BO220, DE440")
    (expect-text (test-id "top-result") "Top result: CE310")
    (expect-text (test-id "result-summary") "Showing 4 of 4 flights.")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 4)
    (expect-metric-delta rows_removed 0)
    (mark-metrics)
    (select-option (label "Sort by") "departure")
    (expect-pending-task "flight-search" 0)
    (expect-text (test-id "sort-summary") "Sorted by: departure time")
    (expect-text (test-id "result-order") "Result order: AU101, CE310, BO220, DE440")
    (expect-text (test-id "top-result") "Top result: AU101")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 4)
  )
)
