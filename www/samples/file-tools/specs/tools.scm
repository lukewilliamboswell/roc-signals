(test "File tools — upload, digest and read a chosen file"
  (setup
    (file "notes.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "File") "notes.txt")
    (click (role button :name "Upload"))
    (expect-upload 1 "notes.txt" 0 3)
    (stub-http "stored" :url "/files/notes.txt" :status 201 :body "stored")
    (run-effect 1)
    (expect-text (test-id "result") "Uploaded: stored")
    (click (role button :name "Digest"))
    (run-effect 2)
    (expect-text (test-id "result") "SHA-256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    (click (role button :name "Read"))
    (run-effect 3)
    (expect-text (test-id "result") "abc")
  )
)
