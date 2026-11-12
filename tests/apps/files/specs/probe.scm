(test "Files — in the worker a file's bytes are an ordinary list: reads agree, slices see them, a change copies"
  (setup
    (file "t.txt" "text/plain" "hello, worker"))
  (steps
    (choose-files (label "Upload") "t.txt")
    (click (role button :name "Probe"))
    (run-effect 1)
    (expect-text (test-id "probe") "probe ok")
    ; The request held the file while it was in flight; the page still does.
    (expect-files 1)
    (click (role button :name "Forget"))
    (click (role button :name "Clear"))
    (expect-files 0)
  )
)
