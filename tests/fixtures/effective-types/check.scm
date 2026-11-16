(test "An invalid input type cannot be checked"
  (setup (initial-location "/#effective-types"))
  (steps
    (check (label "Invalid"))))
