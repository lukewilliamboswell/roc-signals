(test "Pointers — two touches on one paced handler never replace one another"
  (setup (initial-location "/#pointer"))
  (steps
    (pointer-down (test-id "pointer-capture") :pointer touch :id 2)
    (pointer-down (test-id "pointer-capture") :pointer touch :id 3)
    (hold-reports)
    (pointer-move (test-id "pointer-plain") :at 20 50 :id 2)
    (pointer-move (test-id "pointer-plain") :at 80 50 :id 3)
    (expect-reports-replaced 0)
    (release-reports)
    (expect-text (test-id "pointer-log") "down:touch:1:capture:5000:5000|down:touch:1:capture:5000:5000|move:touch:1:plain:2000:5000|move:touch:1:plain:8000:5000")
    (pointer-up (test-id "pointer-plain") :at 20 50 :id 2)
    (pointer-up (test-id "pointer-plain") :at 80 50 :id 3)))
