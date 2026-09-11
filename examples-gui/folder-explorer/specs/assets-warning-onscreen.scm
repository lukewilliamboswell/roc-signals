(scenario "assets-warning-onscreen"
  :window "1200x820"
  :assets "specs/assets-problem"
  ; The asset warning is laid out inside the window, so a person browsing at the
  ; standard size actually sees that a glyph could not be loaded. This guards the
  ; fix for the explorer's height and overflow, which previously put the whole
  ; footer below the window.
  (steps
    (wait 600)
    (expect-visible (text "Problem assets: glyphs/folder.png (altered), glyphs/file.png (missing). Startup check only: glyphs the host cannot load show placeholder boxes. Restart to re-check after restoring them."))
    (expect-onscreen (test-id "asset-status"))))
