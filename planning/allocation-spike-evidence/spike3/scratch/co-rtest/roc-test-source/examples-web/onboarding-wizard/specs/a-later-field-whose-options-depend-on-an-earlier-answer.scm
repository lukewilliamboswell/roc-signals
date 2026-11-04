(test "Onboarding wizard — a later field whose options depend on an earlier answer"
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

    ; 6. a later field whose options depend on an earlier answer
    ;
    ; Growth includes Member and Admin, but not Billing admin.

    (expect-visible (label "Member"))
    (expect-visible (label "Admin"))
    (expect-absent (label "Billing admin"))
    (expect-checked (label "Member") true)
    (expect-text (test-id "invite-role-note") "Growth plans include Member and Admin.")
    (expect-text (test-id "invite-emails-error") "No invites yet. You can add teammates later.")
    (real-click (label "Admin"))
    (expect-checked (label "Admin") true)
    (expect-checked (label "Member") false)
    (expect-text (test-id "summary-invites") "Team invites: 0 invite(s) as Admin (complete)")
  )
)
