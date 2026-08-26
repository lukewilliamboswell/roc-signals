(test "Callable signal identity"
  (steps
    ; Callable signal identity scenario

    (expect-visible (role heading :name "Callable Signal Identity"))
    (expect-attr (test-id "left-map") data-value "1")
    (expect-attr (test-id "right-map") data-value "10")
    (expect-attr (test-id "clone-a") data-value "1")
    (expect-attr (test-id "clone-b") data-value "1")
    (expect-attr (test-id "constant-a") data-value "constant-a")
    (expect-attr (test-id "constant-b") data-value "constant-b")
    (click (role button :name "Increment left"))
    (expect-attr (test-id "left-map") data-value "2")
    (expect-attr (test-id "right-map") data-value "10")
    (expect-attr (test-id "clone-a") data-value "2")
    (expect-attr (test-id "clone-b") data-value "2")
    (click (role button :name "Increment right"))
    (expect-attr (test-id "left-map") data-value "2")
    (expect-attr (test-id "right-map") data-value "11")
    (expect-attr (test-id "clone-a") data-value "2")
    (expect-attr (test-id "clone-b") data-value "2")
  )
)
