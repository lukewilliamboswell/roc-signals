(test "A click delivers pointer events and a prevented pointerdown suppresses mouse and focus"
  (steps
    (click (label "Record click"))
    (expect-text (test-id "press-events") "pointermove;mousemove;pointerdown;mousedown;focus;pointerup;mouseup;click;")
    (expect-focused (label "Record click"))
    (click (label "Record prevented click"))
    (expect-text (test-id "press-events") "pointermove;mousemove;pointerdown;mousedown;focus;pointerup;mouseup;click;pointermove;mousemove;pointerdown;pointerup;click;")
    (expect-focused (label "Record click"))))
