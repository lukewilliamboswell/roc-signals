(scenario "assets-problem"
  :window "1200x820"
  :assets "specs/assets-problem"
  ; Damaged assets. The prepared root alters the folder glyph (still a valid PNG)
  ; and removes the file glyph, so one window shows that verification is advisory:
  ; it names both, while only the glyph the host cannot resolve draws a
  ; placeholder box and folder rows keep their picture. Browsing continues.
  ; Startup verification is a task, so let it settle before reading the line.
  (steps
    (wait 600)
    (expect-visible (text "Problem assets: glyphs/folder.png (altered), glyphs/file.png (missing). Startup check only: glyphs the host cannot load show placeholder boxes. Restart to re-check after restoring them."))
    (expect-count "entry:" 6)
    (snapshot "assets-problem")
    (click (role button :name "docs"))
    (wait 700)
    (expect-disabled (role button :name "Back") false)
    (snapshot "assets-problem-inside-docs")))
