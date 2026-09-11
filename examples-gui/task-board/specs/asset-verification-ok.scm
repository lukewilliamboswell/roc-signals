(test "An all-ok asset verification report leaves the status line empty"
  (setup
    (stub-file-read "maya" :path "/assets/avatars/maya.png" :file "../assets/avatars/maya.png")
    (stub-file-read "jon" :path "/assets/avatars/jon.png" :file "../assets/avatars/jon.png")
    (stub-file-read "sam" :path "/assets/avatars/sam.png" :file "../assets/avatars/sam.png"))
  (steps
    (expect-visible (role heading :name "Launch Board"))
    (expect-text (test-id "asset-status") "")))
