(test "An invalid input type cannot choose files"
  (setup (initial-location "/#effective-types")
    (file "sample.txt" "text/plain" "content"))
  (steps
    (choose-files (label "Invalid") "sample.txt")))
