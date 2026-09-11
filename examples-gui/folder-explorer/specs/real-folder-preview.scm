(scenario "real-folder-preview"
  :window "1200x820"
  :choose ("specs/fixtures/project")
  ; The sample workspace answers every action from memory. A real folder goes
  ; through the native listing, preview and open workers, which is where the
  ; Windows review found Preview text and Open in app inert (GUI-32).
  (steps
    (click (role button :name "Choose folder"))
    (wait 800)
    (expect-count "entry:" 4)
    (click (role button :name "note.txt"))
    (wait 200)
    (expect-disabled (role button :name "Preview text") false)
    (click (role button :name "Preview text"))
    (wait 800)
    (expect-value (label "Text preview") "First line only")
    (snapshot "previewed")
    (click (role button :name "crlf.txt"))
    (wait 200)
    (click (role button :name "Preview text"))
    (wait 800)
    (expect-absent (text "No preview loaded."))
    (snapshot "crlf-previewed")))
