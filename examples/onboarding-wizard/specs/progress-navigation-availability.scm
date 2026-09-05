(test "Onboarding wizard — progress navigation only enables earlier steps"
  (steps
    (expect-disabled (role button :name "Go to Account") true)
    (expect-disabled (role button :name "Go to Organisation") true)
    (expect-disabled (role button :name "Go to Team invites") true)
    (expect-disabled (role button :name "Go to Review") true)

    (fill (label "Work email") "ana@example.com")
    (fill (label "Full name") "Ana Diaz")
    (click (role button :name "Next step"))
    (expect-visible (role region :name "Organisation step"))
    (expect-disabled (role button :name "Go to Account") false)
    (expect-disabled (role button :name "Go to Organisation") true)
    (expect-disabled (role button :name "Go to Team invites") true)
    (expect-disabled (role button :name "Go to Review") true)

    (click (role button :name "Go to Account"))
    (expect-visible (role region :name "Account step"))
    (expect-value (label "Work email") "ana@example.com")
    (expect-value (label "Full name") "Ana Diaz")
    (expect-disabled (role button :name "Go to Account") true)
    (expect-disabled (role button :name "Go to Organisation") true)
  )
)
