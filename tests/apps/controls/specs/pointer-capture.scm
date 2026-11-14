(test "Pointers — capture follows the declaring element and paced moves keep their newest point"
  (setup (initial-location "/#pointer"))
  (steps
    (pointer-down (test-id "pointer-capture"))
    (hold-reports)
    (pointer-move (test-id "pointer-plain") :at 20 30)
    (pointer-move (test-id "pointer-plain") :at 60 70)
    (expect-reports-replaced 1)
    (expect-text (test-id "pointer-log") "down:mouse:1:capture:5000:5000")
    (release-reports)
    (expect-text (test-id "pointer-log") "down:mouse:1:capture:5000:5000|move:mouse:1:plain:6000:7000")
    (pointer-up (test-id "pointer-outside"))
    (expect-text (test-id "pointer-log") "down:mouse:1:capture:5000:5000|move:mouse:1:plain:6000:7000|up:mouse:0:outside")))
