(test "Onboarding wizard — jump backwards to a step, answers preserved"
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
    ; 2. jump backwards to a step, answers preserved

    (click (role button :name "Go to Organisation"))
    (expect-text (test-id "progress-label") "Step 2 of 4 — Organisation")
    (expect-visible (role region :name "Organisation step"))
    (expect-absent (role region :name "Review step"))
    (expect-value (label "Organisation name") "Northwind")
    (expect-value (label "Plan") "growth")
    (expect-checked (label "United States") false)
    (expect-checked (label "European Union") false)
    (expect-text (test-id "org-name-error") "Organisation name looks good.")
    (expect-text (test-id "org-region-error") "Choose a data region.")
    (expect-text (test-id "nav-status") "Complete this step to continue.")
  )
)
