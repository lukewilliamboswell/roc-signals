(scenario "event-space-800x600"
  :window "800x600"
  ; The populated feed at the smaller supported size. The list is laid out inside
  ; the window here; GUI-12 is about how little *useful* space it gets, which is
  ; a judgement this harness deliberately does not encode. What it does guard is
  ; that replay still produces events and the list does not leave the window.
  (steps
    (click (role button :name "Step replay"))
    (wait 400)
    (click (role button :name "Step replay"))
    (wait 400)
    (expect-count "event-" 2)
    (expect-onscreen (test-id "activity-list"))))
