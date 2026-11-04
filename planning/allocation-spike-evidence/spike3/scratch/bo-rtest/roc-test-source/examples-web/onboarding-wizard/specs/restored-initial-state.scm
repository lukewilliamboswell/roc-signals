(test "Onboarding wizard — restored initial state"
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
    ; 1. restored initial state

    (expect-visible (role heading :name "Onboarding Wizard"))
    (expect-visible (role region :name "Progress"))
    (expect-text (test-id "progress-label") "Step 4 of 4 — Review")
    (expect-text (test-id "progress-complete") "2 of 4 steps complete")
    (expect-attr (role region :name "Progress") data-complete "2")
    (expect-text (test-id "summary-account") "Account: ana@example.com / Ana Diaz (complete)")
    (expect-text (test-id "summary-organisation") "Organisation: Northwind on Growth in not chosen (incomplete)")
    (expect-text (test-id "summary-invites") "Team invites: 0 invite(s) as Member (complete)")
    (expect-text (test-id "summary-review") "Review: Finish the earlier steps first (incomplete)")
    (expect-visible (role region :name "Review step"))
    (expect-text (test-id "review-account") "Account: ana@example.com / Ana Diaz (complete)")
    (expect-text (test-id "review-organisation") "Organisation: Northwind on Growth in not chosen (incomplete)")
    (expect-text (test-id "review-invites") "Team invites: 0 invite(s) as Member (complete)")
    (expect-text (test-id "submit-status") "Not submitted yet.")
    (expect-disabled (role button :name "Create workspace") true)
    (expect-text (test-id "nav-status") "Go back and finish the incomplete steps.")
    (expect-disabled (role button :name "Back") false)
    ; Only the active step is mounted.
    (expect-absent (label "Work email"))
    (expect-absent (label "Organisation name"))
    (expect-absent (label "Invite emails"))
  )
)
