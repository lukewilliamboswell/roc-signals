(test "File effects — the SHA-256 digest of a file and of a range of one"
  (setup
    (file "abc.txt" "text/plain" "abc")
    (file "two.txt" "text/plain" "xxabc"))
  (steps
    (choose-files (label "Upload") "abc.txt")
    (click (role button :name "Digest"))
    (expect-text (test-id "digest") "waiting")
    (run-effect 1)
    (expect-text (test-id "digest") "sha256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    (click (role button :name "Clear"))
    (choose-files (label "Upload") "two.txt")
    ; The second half of "xxabc" is "abc" (offset 2, three bytes).
    (click (role button :name "Digest tail"))
    (run-effect 2)
    (expect-text (test-id "digest") "sha256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    (click (role button :name "Digest"))
    (run-effect 3)
    (expect-text (test-id "digest") "sha256 5cb5a98ab4819f77b32bbcf80732888850d94fbf896f64d5c4b64722dab39154")
  )
)
