(scenario "inspector-800x600"
  :window "800x600"
  ; The smaller supported size. Every band the application declares has to be
  ; laid out inside the window, not below it: the list, the inspector a person
  ; reads their selection from, and the footer carrying the shortcut hint and
  ; any asset problem. `expect-onscreen` reads recorded layout bounds, so it
  ; judges those regions directly; the entries and the preview editor sit
  ; inside scrolling regions the bounds probe does not record, so they are
  ; asserted by what they hold and what they accept instead.
  (steps
    (expect-onscreen (test-id "file-list"))
    (expect-onscreen (test-id "file-details"))
    (expect-onscreen (test-id "shortcut-hints"))
    (expect-onscreen (test-id "dataset-summary"))
    (expect-count "entry:" 6)
    (snapshot "initial")
    (click (role button :name "README.md"))
    (wait 700)
    (expect-selected (test-id "entry:README.md") true)
    (expect-visible (text "Size: 1536 B"))
    (expect-onscreen (test-id "file-details"))
    (click (role button :name "Preview text"))
    (wait 900)
    (expect-visible (text "Preview: README.md"))
    (expect-onscreen (test-id "file-list"))
    (expect-onscreen (test-id "shortcut-hints"))
    (snapshot "previewed")))
