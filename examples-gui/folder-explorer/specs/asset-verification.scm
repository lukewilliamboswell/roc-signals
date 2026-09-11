(test "Startup glyph verification names problem assets advisorily and browsing continues"
  (setup
    (stub-file-read "folder-glyph" :path "/assets/glyphs/folder.png" :file "../assets/glyphs/folder.png")
    (stub-file-read "file-glyph" :path "/assets/glyphs/file.png" :text "altered"))
  (steps
    (expect-visible (role heading :name "Folder Explorer"))
    (expect-text (test-id "asset-status") "Problem assets: glyphs/file.png (altered). Startup check only: glyphs the host cannot load show placeholder boxes. Restart to re-check after restoring them.")
    (click (role button :name "Use sample"))
    (expect-visible (test-id "entry:docs"))))
