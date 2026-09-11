(scenario "assets-problem"
  :window "1200x820"
  :assets "specs/assets-problem"
  ; Damaged assets. The prepared root alters maya (still a valid PNG), removes
  ; jon, and leaves sam unreadable, so one window shows that verification is
  ; advisory: it names all three, while only the two the host cannot load draw
  ; placeholder boxes and the altered avatar keeps rendering. The board stays
  ; fully usable, which is the point of not gating rendering on the report.
  ; Startup verification is a task, so let it settle before reading the line.
  (steps
    (wait 600)
    ; A warning nobody can see is not a warning: this line must hold real area
    ; inside the window, not merely exist in the semantic tree.
    (expect-onscreen (test-id "asset-status"))
    (expect-visible (text "Problem assets: avatars/maya.png (altered), avatars/jon.png (missing), avatars/sam.png (altered). Startup check only: avatars the host cannot load show placeholder boxes. Restart to re-check after restoring them."))
    (expect-count "task-" 8)
    (expect-selected (test-id "task-1") true)
    (snapshot "assets-problem")
    (click (test-id "edit-task-4"))
    (wait 400)
    (expect-selected (test-id "task-4") true)
    (expect-value (label "Task title") "Polish the project sidebar")
    (snapshot "assets-problem-selected")))
