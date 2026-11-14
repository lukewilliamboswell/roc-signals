(test "Files — a worker task reads the bytes of the files it is sent, and of a range of one"
  (setup
    (file "a.txt" "text/plain" "abc")
    (file "b.csv" "text/csv" "xy" 500))
  (steps
    (choose-files (label "Upload") "a.txt" "b.csv")
    (click (role button :name "Count"))
    (expect-text (test-id "counts") "counting")
    (expect-pending-work "test.roc-signals/files/count" 1)
    (run-effect 1)
    ; a+b+c = 97+98+99; (x+y) * 500 = (120+121) * 500.
    (expect-text (test-id "counts") "a.txt:3:294|b.csv:1000:120500")
    ; The second half of a.txt: one byte, "c" (99) at offset 1 of 3.
    (click (role button :name "Count tail"))
    (run-effect 2)
    (expect-text (test-id "counts") "a.txt:2:197")
  )
)
