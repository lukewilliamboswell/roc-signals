(test "Onboarding wizard — back to step 1: editing one field leaves the other alone"
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

    ; 11. back to step 1: editing one field leaves the other alone

    (click (role button :name "Go to Account"))
    (expect-text (test-id "progress-label") "Step 1 of 4 — Account")
    (expect-value (label "Work email") "ana@example.com")
    (expect-value (label "Full name") "Ana Diaz")
    (expect-disabled (role button :name "Back") true)
    ; Both fields live in one Account handle, but each input is its own signal
    ; sink: editing one leaves the other's value untouched.
    (expect-updates (label "Work email") 1)
    (mark-metrics)
    (fill (label "Full name") "Ana Diaz-Ruiz")
    (expect-updates (label "Work email") 1)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta rows_reused 4)
    (expect-metric-delta rows_created 0)
    (expect-text (test-id "account-name-error") "Full name looks good.")
    (expect-text (test-id "account-email-error") "Work email looks good.")
    ; Invalid input: per-field message, aria-invalid, and blocked navigation.
    (fill (label "Work email") "ana@")
    (expect-text (test-id "account-email-error") "Work email must look like name@example.com.")
    (expect-attr (label "Work email") aria-invalid "")
    (click (role button :name "Next step"))
    (expect-visible (role region :name "Account step"))
    (expect-text (test-id "progress-label") "Step 1 of 4 — Account")
    (fill (label "Work email") "")
    (expect-text (test-id "account-email-error") "Work email is required.")
    (fill (label "Work email") "ana@example.com")
    (expect-no-attr (label "Work email") aria-invalid)
    (click (role button :name "Next step"))
    (expect-text (test-id "progress-label") "Step 2 of 4 — Organisation")
  )
)
