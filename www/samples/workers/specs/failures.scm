(test "Words — a job that times out or is lost says so, and the page keeps working"
  (steps
    (run-effect 1)
    (run-effect 2)
    (click (role button :name "Count words"))
    (expect-pending-work "example.org/words/frequencies" 1)
    ; The count has a five-second deadline. A spec's time only moves when it
    ; says so: here the deadline expires before the job answers.
    (mark-metrics)
    (time-out-work 3)
    (expect-text (test-id "counted") "This took too long.")
    (expect-metric-delta effects_delivered 1)
    (expect-pending-effects 0)
    ; A job can also be lost: its worker crashed, ran out of memory, or there
    ; is none. The view shows the same failure for every cause.
    (fill (label "Numbers") "1 2")
    (lose-work 4 out_of_memory)
    (expect-text (test-id "total") "Adding failed.")
    ; Nothing else broke: the next jobs answer as usual.
    (fill (label "Numbers") "1 2 3")
    (run-effect 5)
    (expect-text (test-id "total") "Total 6")
    (click (role button :name "Count words"))
    (run-effect 6)
    (expect-text (test-id "counted") "the 2, cat 1, saw 1")
    (expect-metric-delta effects_cancelled 0)
  )
)
