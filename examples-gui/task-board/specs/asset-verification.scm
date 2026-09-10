(test "Startup asset verification names missing and altered assets and keeps the board editable"
  (steps
    (expect-visible (role heading :name "Launch Board"))
    (expect-pending-task "asset-verify" 1)
    (resolve-file-assets "asset-verify" :entries ((ok "avatars/maya.png") (missing "avatars/jon.png") (mismatch "avatars/sam.png")))
    (expect-pending-task "asset-verify" 0)
    (expect-text (test-id "asset-status") "Problem assets: avatars/jon.png (missing), avatars/sam.png (altered). Startup check only: avatars the host cannot load show placeholder boxes. Restart to re-check after restoring them.")
    (fill (label "New task title") "Board still edits with placeholder avatars")
    (click (role button :name "Add task"))
    (expect-visible (test-id "task-7"))))
