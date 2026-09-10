(test "An all-ok asset verification report leaves the status line empty"
  (setup
    (stub-file-assets "asset-verify" :entries ((ok "avatars/maya.png") (ok "avatars/jon.png") (ok "avatars/sam.png"))))
  (steps
    (expect-visible (role heading :name "Launch Board"))
    (expect-text (test-id "asset-status") "")))
