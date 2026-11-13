(test "File effects — the page reads a file's text and bytes, and a range of one"
  (setup
    (file "a.txt" "text/plain" "héllo")
    (file "b.csv" "text/csv" "xy" 3))
  (steps
    (choose-files (label "Upload") "a.txt" "b.csv")
    (expect-text (test-id "files") "a.txt:6:text/plain|b.csv:6:text/csv")
    (click (role button :name "Read text"))
    (expect-text (test-id "read") "reading")
    (expect-pending-effects 1)
    (run-effect 1)
    (expect-text (test-id "read") "text héllo")
    ; h + é (0xC3 0xA9) + l + l + o = 104 + 195 + 169 + 108 + 108 + 111.
    (click (role button :name "Read bytes"))
    (run-effect 2)
    (expect-text (test-id "read") "bytes 6 sum 795")
    ; The second half: "llo".
    (click (role button :name "Read tail"))
    (run-effect 3)
    (expect-text (test-id "read") "bytes 3 sum 327")
    (expect-pending-effects 0)
    ; Each read was answered and held nothing once it was: the app's state
    ; and the read site's last input hold the one file.
    (click (role button :name "Forget"))
    (click (role button :name "Clear"))
    (expect-files 0)
  )
)
