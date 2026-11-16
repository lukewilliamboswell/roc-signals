(test "Pointers — a full U32 logical touch id is independent of the browser's contact slots"
  (setup (initial-location "/#pointer"))
  (steps
    (pointer-down (test-id "pointer-capture") :pointer touch :id 4294967295)
    (pointer-up (test-id "pointer-capture") :id 4294967295)
    (expect-text (test-id "pointer-log") "down:touch:1:capture:5000:5000|up:touch:0:capture:5000:5000")))
