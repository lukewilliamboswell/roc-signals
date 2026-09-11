(scenario "assets-healthy"
  :window "1200x820"
  ; Healthy assets, which is also the restored state: verification runs once at
  ; mount, so a repaired root is reported by the next run, and this is that run.
  ; The shipped root must produce no warning line at all — the exact sentence the
  ; damaged-root scenario asserts must be absent here.
  ; Startup verification is a task, so let it settle before reading the line.
  (steps
    (wait 600)
    ; The check ran and reported nothing: the in-progress line has cleared and no
    ; warning replaced it.
    (expect-absent (text "Checking assets…"))
    (expect-absent (text "Problem assets: glyphs/folder.png (altered), glyphs/file.png (missing). Startup check only: glyphs the host cannot load show placeholder boxes. Restart to re-check after restoring them."))
    (expect-count "entry:" 6)
    (snapshot "assets-healthy")))
