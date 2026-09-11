(scenario "preview-is-readable-1200x820"
  :window "1200x820"
  ; GUI-11. A loaded preview is a document to read, not an unavailable control.
  ; It must stay in the tab order, take focus, and hold the loaded text; and it
  ; must refuse every edit, so the shown text cannot drift from the preview the
  ; application loaded. Native undo depth is the check for that last part: a
  ; refused keystroke leaves no edit history behind.
  (steps
    (click (role button :name "README.md"))
    (wait 700)
    (click (role button :name "Preview text"))
    (wait 900)
    (expect-visible (text "Preview: README.md"))
    (expect-disabled (test-id "text-preview") false)
    (focus (test-id "text-preview"))
    (expect-focused (test-id "text-preview"))
    (expect-history (test-id "text-preview") 0)
    (type (test-id "text-preview") "edited")
    (key "backspace")
    (key "ctrl-z")
    (expect-history (test-id "text-preview") 0)
    (expect-visible (text "Preview: README.md"))
    (snapshot "preview-focused")))
