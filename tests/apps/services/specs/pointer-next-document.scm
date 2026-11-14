(test "Services — an explicit pointer release mounts the link's next document"
  (steps
    (fill (label "Trimmed") "old document")
    (pointer-down (role link :name "Next pointer document"))
    (expect-text (test-id "trimmed") "old document")
    (pointer-up (role link :name "Next pointer document"))
    (expect-current-location "/pointer-next-document")
    (expect-text (test-id "trimmed") "")
  )
)
