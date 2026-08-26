(test "Onboarding wizard — editing step 2 does not re render step 1's fields"
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

    ; 4. editing step 2 does not re render step 1's fields
    ;
    ; The progress list is one Ui.each_str over a Signal.combine of four
    ; per-step summary signals. Editing the organisation name recomputes only
    ; org_summary and the combined list; the account row keeps its scope, its row
    ; is reused, and its text sink never fires.

    (expect-updates (test-id "summary-account") 2)
    (mark-metrics)
    (fill (label "Organisation name") "Northwind Labs")
    (expect-text (test-id "summary-organisation") "Organisation: Northwind Labs on Growth in not chosen (incomplete)")
    (expect-text (test-id "summary-account") "Account: ana@example.com / Ana Diaz (complete)")
    (expect-updates (test-id "summary-account") 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 4)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta derived_calls_into_roc 21)
    (expect-metric-delta-at-most patches_emitted 6)
  )
)
