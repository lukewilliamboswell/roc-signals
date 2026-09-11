(scenario "selection-and-drafts"
  :window "1200x820"
  ; Selection, focus and per-row editor identity. Keyed rows is the example that
  ; teaches row identity, so the presentation layer has to agree with it: the
  ; selected row is the one the person clicked, and each row's draft belongs to
  ; that row's own editor.
  (steps
    (expect-count "row-" 3)
    (expect-selected (test-id "row-Alpha") true)
    (click (role button :name "Select Beta"))
    (wait 200)
    (expect-selected (test-id "row-Beta") true)
    (expect-selected (test-id "row-Alpha") false)
    (snapshot "beta-selected")
    (type (label "Draft Beta") "hello")
    (wait 250)
    (expect-value (label "Draft Beta") "hello")
    (expect-value (label "Draft Alpha") "")
    (expect-focused (text "Draft Beta"))
    (click (role button :name "Move first to end"))
    (wait 250)
    (expect-count "row-" 3)
    (expect-value (label "Draft Beta") "hello")
    (snapshot "after-move")
    (click (role button :name "Hide / show rows"))
    (wait 250)
    (expect-count "row-" 0)
    (click (role button :name "Hide / show rows"))
    (wait 250)
    (expect-count "row-" 3)))
