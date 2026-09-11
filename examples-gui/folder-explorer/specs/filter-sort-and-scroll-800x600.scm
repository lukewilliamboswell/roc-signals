(scenario "filter-sort-and-scroll-800x600"
  :window "800x600"
  ; Filtering, ordering and list scrolling at the smaller size. The list is a
  ; virtual viewport, so its rows are inside a scrolling region the bounds probe
  ; does not record: reachability is asserted by selecting the row that starts
  ; below the fold rather than by `expect-onscreen`. Both summaries and the
  ; footer must stay laid out inside the window throughout.
  (steps
    (expect-count "entry:" 6)
    (expect-visible (text "6 matching entries"))
    (expect-onscreen (test-id "results-summary"))
    (expect-onscreen (test-id "shortcut-hints"))
    ; The last entry starts below the fold at this height; selecting it proves the
    ; list scrolls to reach it rather than laying it out past the window.
    (click (role button :name "release-notes.md"))
    (wait 700)
    (expect-selected (test-id "entry:release-notes.md") true)
    (snapshot "scrolled-to-last")
    (click (role button :name "Largest files"))
    (wait 300)
    (expect-selected (test-id "entry:release-notes.md") true)
    (expect-onscreen (test-id "dataset-summary"))
    (type (label "Filter this folder") "md")
    (wait 500)
    (expect-visible (text "2 matching entries"))
    (expect-onscreen (test-id "file-list"))
    (expect-onscreen (test-id "file-details"))
    (expect-onscreen (test-id "shortcut-hints"))
    (snapshot "filtered-and-sorted")
    (click (role button :name "Clear filter"))
    (wait 500)
    (expect-visible (text "6 matching entries"))))
