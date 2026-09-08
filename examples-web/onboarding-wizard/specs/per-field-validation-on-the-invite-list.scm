(test "Onboarding wizard — per field validation on the invite list"
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

    ; 7. per field validation on the invite list

    (fill (label "Invite emails") "bo@example.com, not-an-email")
    (expect-text (test-id "invite-emails-error") "Not a valid email: not-an-email")
    (click (role button :name "Next step"))
    (expect-visible (role region :name "Team invites step"))
    (expect-text (test-id "progress-label") "Step 3 of 4 — Team invites")
    (expect-text (test-id "summary-invites") "Team invites: 2 invite(s) as Admin (incomplete)")
    (fill (label "Invite emails") "bo@example.com, cy@example.com")
    (expect-text (test-id "invite-emails-error") "2 invite(s) ready.")
    (expect-text (test-id "summary-invites") "Team invites: 2 invite(s) as Admin (complete)")
  )
)
