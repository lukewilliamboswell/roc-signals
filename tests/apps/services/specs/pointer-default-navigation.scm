(test "Services — an explicit pointer release follows an ordinary link"
  (steps
    (pointer-down (role link :name "Jump"))
    (pointer-up (role link :name "Jump"))
    (expect-current-location "/#jump")
    (history-back)
    (expect-current-location "/")
  )
)
