(test "Onboarding wizard — changing the earlier answer RESETS the dependent field"
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

    ; 8. changing the earlier answer RESETS the dependent field
    ;
    ; Documented decision: dropping to Starter does not merely hide the Admin
    ; option, it writes Member back into the role handle. Returning to Growth does
    ; not restore Admin.

    (click (role button :name "Go to Organisation"))
    (select-option (label "Plan") "starter")
    (expect-value (label "Plan") "starter")
    (expect-text (test-id "summary-invites") "Team invites: 2 invite(s) as Member (complete)")
    (expect-text (test-id "summary-organisation") "Organisation: Northwind Labs on Starter in European Union (complete)")
    (click (role button :name "Next step"))
    (expect-visible (role region :name "Team invites step"))
    (expect-absent (label "Admin"))
    (expect-absent (label "Billing admin"))
    (expect-checked (label "Member") true)
    (expect-text (test-id "invite-role-note") "Starter plans have one role. Upgrade to invite admins.")
    (expect-value (label "Invite emails") "bo@example.com, cy@example.com")
  )
)
