(test "Onboarding wizard — an invalid step blocks navigation"
  (setup
    ; Onboarding Wizard
    ;
    ; The app mounts with a part-finished draft in local storage, so the "initial
    ; state" this spec asserts first is the *restored* one: step 4 (Review), with
    ; the organisation step still missing a data region. The empty/initial state is
    ; asserted at the end, after "Start over" clears every handle and removes the
    ; saved draft.

    (local-storage "onboarding:draft" "ana@example.com|Ana Diaz|Northwind|growth|||member|review")
  )
  (steps
    ; Given the state established by earlier scenarios
    (click (role button :name "Go to Organisation"))

    ; 3. an invalid step blocks navigation

    (click (role button :name "Next step"))
    (expect-visible (role region :name "Organisation step"))
    (expect-text (test-id "progress-label") "Step 2 of 4 — Organisation")
  )
)
