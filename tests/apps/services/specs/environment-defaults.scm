(test "Services — an unset environment boots online and visible"
  (steps
    (expect-text (test-id "online") "online")
    (expect-text (test-id "visible") "visible")
    (expect-text (test-id "storage") "storage available")))
