(test "Onboarding wizard — fix the step and move on"
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
    (click (role button :name "Next step"))
    (mark-metrics)
    (fill (label "Organisation name") "Northwind Labs")

    ; 5. fix the step and move on

    (real-click (label "European Union"))
    (expect-checked (label "European Union") true)
    (expect-text (test-id "org-region-error") "Data stored in European Union.")
    (expect-text (test-id "nav-status") "Ready for the next step.")
    (expect-text (test-id "progress-complete") "4 of 4 steps complete")
    (click (role button :name "Next step"))
    (expect-text (test-id "progress-label") "Step 3 of 4 — Team invites")
    (expect-visible (role region :name "Team invites step"))
  )
)
