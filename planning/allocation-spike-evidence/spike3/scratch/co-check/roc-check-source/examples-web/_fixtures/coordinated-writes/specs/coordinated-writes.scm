(test "Independent states commit together and cached commands remain reusable"
  (setup (manual-effects))
  (steps
    (expect-text (test-id "pair") "A:B")
    (click (role button :name "Cached single"))
    (click (role button :name "Cached single"))
    (expect-pending-effects 0)


    (click (role button :name "Swap"))
    (expect-text (test-id "pair") "B:A")
    (expect-text (test-id "branch-value") "A")
    (expect-pending-effects 1)



    (click (role button :name "Swap reversed"))
    (expect-text (test-id "pair") "A:B")
    (expect-absent (test-id "branch-value"))



    (click (role button :name "Swap"))
    (click (role button :name "Cached reset"))
    (expect-text (test-id "pair") "A:B")

    (click (role button :name "Cached reset"))
    (expect-text (test-id "pair") "A:B")
    (expect-pending-effects 4)


    ; Every observer retained a settled snapshot, never a partial A:A or B:B.
    (expect-pending-effects 4)
    (run-effect 1)
    (expect-text (test-id "observed") "B:A")
    (run-effect 2)
    (expect-text (test-id "observed") "B:A;A:B")
    (run-effect 3)
    (run-effect 4)
    (expect-text (test-id "observed") "B:A;A:B;B:A;A:B")
    (expect-pending-effects 0)
  )
)
