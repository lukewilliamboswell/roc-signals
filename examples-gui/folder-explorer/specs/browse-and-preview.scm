(scenario "browse-and-preview"
  :window "1200x820"
  ; Initial, populated, selected, loading and read-only states. The preview field
  ; is the example's read-only control — available and keyboard reachable, but
  ; refusing edits — and navigation is what makes Back, Up and the breadcrumbs
  ; meaningful; all of these are rules a screenshot of the first frame cannot
  ; check. Read-only is asserted apart from disabled: an empty preview is still
  ; a control a person can tab into.
  (steps
    (expect-disabled (role button :name "Back") true)
    (expect-disabled (role button :name "Up") true)
    (expect-disabled (role button :name "Preview text") true)
    (expect-disabled (test-id "text-preview") false)
    (expect-count "entry:" 6)
    (snapshot "initial")
    (click (role button :name "docs"))
    (wait 700)
    (expect-disabled (role button :name "Back") false)
    (expect-disabled (role button :name "Up") false)
    (snapshot "inside-docs")
    (click (role button :name "Back"))
    (wait 700)
    (expect-disabled (role button :name "Back") true)
    (expect-count "entry:" 6)
    (click (role button :name "README.md"))
    (wait 700)
    (expect-selected (test-id "entry:README.md") true)
    (expect-disabled (role button :name "Preview text") false)
    (snapshot "file-selected")
    (click (role button :name "Preview text"))
    (wait 900)
    (expect-disabled (test-id "text-preview") false)
    (expect-history (test-id "text-preview") 0)
    (snapshot "previewed")))
