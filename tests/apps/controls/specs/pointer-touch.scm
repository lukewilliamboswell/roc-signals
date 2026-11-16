(test "Pointers — a moved touch cancels without mouse compatibility events"
  (setup (initial-location "/#pointer"))
  (steps
    (pointer-down (test-id "pointer-capture") :pointer touch)
    (pointer-move (test-id "pointer-plain") :at 80 50 :id 2)
    (pointer-cancel)
    (expect-text (test-id "pointer-log") "down:touch:1:capture:5000:5000|move:touch:1:plain:8000:5000|cancel:touch:0:outside")))
