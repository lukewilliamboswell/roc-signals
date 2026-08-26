(test "Onboarding wizard — start over: the empty initial state"
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
    (click (role button :name "Next step"))
    (click (role button :name "Create workspace"))
    (click (role button :name "Create workspace"))
    (resolve-stale-task "onboarding-submit" "stale-workspace")
    (resolve-task "onboarding-submit" "acme-42")
    (click (role button :name "Create workspace"))
    (reject-task "onboarding-submit" "region unavailable")
    (click (role button :name "Go to Account"))
    (mark-metrics)
    (fill (label "Full name") "Ana Diaz-Ruiz")
    (fill (label "Work email") "ana@")
    (click (role button :name "Next step"))
    (fill (label "Work email") "")
    (fill (label "Work email") "ana@example.com")
    (click (role button :name "Next step"))

    ; 12. start over: the empty initial state

    (click (role button :name "Start over"))
    (expect-text (test-id "progress-label") "Step 1 of 4 — Account")
    (expect-text (test-id "progress-complete") "1 of 4 steps complete")
    (expect-attr (role region :name "Progress") data-complete "1")
    (expect-text (test-id "summary-account") "Account: No email yet (incomplete)")
    (expect-text (test-id "summary-organisation") "Organisation: No organisation yet (incomplete)")
    (expect-text (test-id "summary-invites") "Team invites: 0 invite(s) as Member (complete)")
    (expect-text (test-id "summary-review") "Review: Finish the earlier steps first (incomplete)")
    (expect-visible (role region :name "Account step"))
    (expect-value (label "Work email") "")
    (expect-value (label "Full name") "")
    (expect-text (test-id "account-email-error") "Work email is required.")
    (expect-text (test-id "account-name-error") "Full name is required.")
    (expect-text (test-id "nav-status") "Complete this step to continue.")
    (expect-disabled (role button :name "Back") true)
    (expect-no-local-storage "onboarding:draft")
    ; A single character is enough to start saving again.
    (fill (label "Full name") "B")
    (expect-local-storage "onboarding:draft" "|B||starter|||member|account")
  )
)
