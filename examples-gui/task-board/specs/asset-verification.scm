(test "Startup asset verification names missing and altered assets and keeps the board editable"
  (setup
    (stub-file-read "maya" :path "/assets/avatars/maya.png" :file "../assets/avatars/maya.png")
    (stub-file-reject "jon" :kind not-found :detail "/assets/avatars/jon.png")
    (stub-file-read "sam" :path "/assets/avatars/sam.png" :text "altered"))
  (steps
    (expect-visible (role heading :name "Launch Board"))
    (expect-text (test-id "asset-status") "Problem assets: avatars/jon.png (missing), avatars/sam.png (altered). Startup check only: avatars the host cannot load show placeholder boxes. Restart to re-check after restoring them.")
    (fill (label "New task title") "Board still edits with placeholder avatars")
    (click (role button :name "Add task"))
    (expect-visible (test-id "task-7"))))
