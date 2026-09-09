(test "Startup glyph verification names problem assets and browsing continues with placeholders"
  (steps
    (expect-visible (role heading :name "Folder Explorer"))
    (expect-pending-task "asset-verify" 1)
    (resolve-file-assets "asset-verify" :entries ((ok "glyphs/folder.png") (mismatch "glyphs/file.png")))
    (expect-pending-task "asset-verify" 0)
    (expect-text (test-id "asset-status") "Problem assets: glyphs/file.png (altered). Rows show placeholder boxes until the assets are restored.")
    (click (role button :name "Use sample"))
    (expect-visible (test-id "entry:docs"))))
