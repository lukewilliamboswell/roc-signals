(test "Signal combine caps"
  (steps
    ; Signal.combine over signals that own separate capabilities.
    ;
    ; Regression test: combine used to read every element through the first
    ; signal's capability, which aborted with "HostValue operation used a
    ; capability that does not own the retained value" as soon as the inputs came
    ; from different call sites.
    ;
    ; Also demonstrates the non-fragile locator style: dynamic text carries a
    ; test_id, so the locator is stable and the assertion reports a value diff
    ; rather than a missing element when the value changes.

    (expect-visible (role region :name "Combine"))
    (expect-text (test-id "left") "Left: 1")
    (expect-text (test-id "joined") "Joined: 1+10")
    (click (role button :name "Bump left"))
    (expect-text (test-id "left") "Left: 2")
    (expect-text (test-id "joined") "Joined: 2+10")
    ; expect_text falls back to concatenated descendant text for a container with
    ; no text field of its own. Useful for seeing what actually rendered.
    (expect-text (role region :name "Combine") "CombineLeft: 2Joined: 2+10Bump left")
  )
)
