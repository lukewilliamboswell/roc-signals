(test "typed clicks capture the nearest managed link and keyboard activation"
  (steps
    (click (test-id "nested"))
    (expect-text (test-id "clicks") "{ alt: False, ctrl: False, link: Link({ download: False, href: \"/valid\", target: \"\" }), meta: False, shift: False }")
    (focus (test-id "checked"))
    (press "Enter")
    (expect-current-location "/")
    (pointer-down (test-id "nested") :modifiers (shift alt meta))
    (pointer-up (test-id "nested"))
    (expect-text (test-id "clicks") "{ alt: True, ctrl: False, link: Link({ download: False, href: \"/valid\", target: \"\" }), meta: True, shift: True }")
    (click (role button :name "No link"))
    (expect-text (test-id "clicks") "{ alt: False, ctrl: False, link: NoLink, meta: False, shift: False }")))
