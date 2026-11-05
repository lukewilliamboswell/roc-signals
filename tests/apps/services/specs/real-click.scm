(test "Services — real clicks deliver mouse events in order and take default actions"
  (steps
    ; Chrome moves focus as the default action of the press, between
    ; mousedown and mouseup.
    (real-click (role button :name "Press"))
    (expect-text (test-id "presses") "mousedown,focus,mouseup,click")
    (real-click (label "Medium"))
    (expect-checked (label "Medium") true)
    (expect-checked (label "Small") false)
    (expect-text (test-id "size") "m")
    (change (label "Small") "s")
    (expect-checked (label "Small") true)
    (expect-text (test-id "size") "s")
    (real-click (label "Agree"))
    (expect-checked (label "Agree") true)
    (real-click (label "Agree"))
    (expect-checked (label "Agree") false)
  )
)
