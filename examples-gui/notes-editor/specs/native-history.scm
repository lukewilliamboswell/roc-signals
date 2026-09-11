(scenario "native-history"
  :window "1200x820"
  ; The native editing history belongs to the document being edited. Typing
  ; builds one grouped entry; undoing it returns the draft the person started
  ; from. Only the host can see this, which is why GUI-01 and GUI-02 survived
  ; both the semantic specs and the first-frame screenshots.
  (steps
    (expect-history (label "Note text") 0)
    (type (label "Note text") "hello")
    (wait 400)
    (expect-value (label "Note text") "hello")
    (expect-history (label "Note text") 1)
    (key "ctrl-z")
    (wait 400)
    (expect-value (label "Note text") "")
    (expect-history (label "Note text") 0)))
