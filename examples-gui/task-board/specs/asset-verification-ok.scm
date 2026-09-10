(test "An all-ok asset verification report leaves the status line empty"
  (steps
    (expect-visible (role heading :name "Launch Board"))
    (expect-pending-task "asset-verify" 1)
    (expect-text (test-id "asset-status") "Checking assets…")
    (resolve-file-assets "asset-verify" :entries ((ok "avatars/maya.png") (ok "avatars/jon.png") (ok "avatars/sam.png")))
    (expect-pending-task "asset-verify" 0)
    (expect-text (test-id "asset-status") "")))
