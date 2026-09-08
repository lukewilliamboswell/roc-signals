(test "Styled branch replacement retires native scalar descriptors"
  (steps
    (expect-text (test-id "styled-branch") "First branch")
    (click (role button :name "Switch branch"))
    (expect-text (test-id "styled-branch") "Second branch")
    (click (role button :name "Switch branch"))
    (expect-text (test-id "styled-branch") "First branch")))
