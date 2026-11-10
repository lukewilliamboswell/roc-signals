(test "File effects — a read reports bytes that are not UTF-8, and a file larger than a read takes, as typed failures"
  (setup
    (file "a.txt" "text/plain" "héllo")
    ; 8 MiB and 8 bytes: one range more than the default maxReadBytes.
    (file "big.bin" "application/octet-stream" "abcdefgh" 1048577))
  (steps
    (choose-files (label "Upload") "a.txt")
    ; The second byte alone is the first half of "é".
    (click (role button :name "Read cut"))
    (run-effect 1)
    (expect-text (test-id "read") "failed InvalidUtf8")
    (click (role button :name "Clear"))
    (choose-files (label "Upload") "big.bin")
    (click (role button :name "Read bytes"))
    (run-effect 2)
    (expect-text (test-id "read") "failed TooLarge")
  )
)
