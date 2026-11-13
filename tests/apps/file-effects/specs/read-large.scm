(test "File effects — a read that accepts more takes a file larger than the default"
  (setup
    ; 8 MiB and 8 bytes: more than a read accepts by default, less than
    ; the 64 MiB "Read large" asks for.
    (file "big.txt" "text/plain" "abcdefgh" 1048577))
  (steps
    (choose-files (label "Upload") "big.txt")
    (click (role button :name "Read large"))
    (run-effect 1)
    (expect-text (test-id "read") "bytes 8388616 sum 843055908")
  )
)
