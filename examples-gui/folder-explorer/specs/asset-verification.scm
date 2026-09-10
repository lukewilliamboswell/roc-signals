(test "Startup glyph verification names problem assets advisorily and browsing continues"
  (steps
    (expect-visible (role heading :name "Folder Explorer"))
    (expect-pending-task "asset-verify" 1)
    (expect-text (test-id "asset-status") "Checking assets…")
    (resolve-file-assets "asset-verify" :entries ((ok "glyphs/folder.png") (mismatch "glyphs/file.png")))
    (expect-pending-task "asset-verify" 0)
    (expect-text (test-id "asset-status") "Problem assets: glyphs/file.png (altered). Startup check only: glyphs the host cannot load show placeholder boxes. Restart to re-check after restoring them.")
    (click (role button :name "Use sample"))
    (expect-visible (test-id "entry:docs"))))
