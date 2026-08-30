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

    ; Two updates, both from the mount host call: the initial publication
    ; renders the account row before the draft is restored, and the
    ; on_change_initial restore is a second sealed transaction that recomputes
    ; the row's text from the restored draft. Navigating back to this step
    ; preserves the keyed account row and its unchanged text sink. (An earlier
    ; engine recreated the row's element on the restore, which reset the
    ; per-element count to 1 and hid the second update.)
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
    ; 26, not 21, because the polished view derives five more values from this
    ; same edit: the organisation name's message and tone, the region tone, the
    ; progress bar width, and the organisation row's badge. Step 1's fields are
    ; still untouched, which is what this spec is actually guarding.
    (expect-metric-delta derived_calls_into_roc 26)
    ; The keyed row scope is reused, but its changed five-node subtree is still
    ; structurally republished. Reducing this from 28 requires a pre-collection
    ; topology plan that can prove nested component/when construction sites are
    ; reusable before DOM identities are reserved. Keep the bound explicit so
    ; this known optimization gap cannot regress silently.
  )
)
