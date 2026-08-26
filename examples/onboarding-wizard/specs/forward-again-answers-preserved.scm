(test "Onboarding wizard — forward again, answers preserved"
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
    (real-click (label "European Union"))
    (click (role button :name "Next step"))
    (real-click (label "Admin"))
    (fill (label "Invite emails") "bo@example.com, not-an-email")
    (click (role button :name "Next step"))
    (fill (label "Invite emails") "bo@example.com, cy@example.com")
    (click (role button :name "Go to Organisation"))
    (select-option (label "Plan") "starter")
    (click (role button :name "Next step"))

    ; 9. forward again, answers preserved

    (click (role button :name "Next step"))
    (expect-text (test-id "progress-label") "Step 4 of 4 — Review")
    (expect-text (test-id "progress-complete") "4 of 4 steps complete")
    (expect-attr (role region :name "Progress") data-complete "4")
    (expect-text (test-id "review-account") "Account: ana@example.com / Ana Diaz (complete)")
    (expect-text (test-id "review-organisation") "Organisation: Northwind Labs on Starter in European Union (complete)")
    (expect-text (test-id "review-invites") "Team invites: 2 invite(s) as Member (complete)")
    (expect-disabled (role button :name "Create workspace") false)
    (expect-text (test-id "nav-status") "Everything checks out. Create the workspace.")
    (expect-local-storage "onboarding:draft" "ana@example.com|Ana Diaz|Northwind Labs|starter|eu|bo@example.com, cy@example.com|member|review")
  )
)
