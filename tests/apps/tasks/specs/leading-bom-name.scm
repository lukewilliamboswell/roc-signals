(test "Tasks — a worker preserves leading U+FEFF in a file it builds"
  ; U+FEFF is the first character of the quoted file names below, not a file signature.
  (setup
    (file "﻿notes.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "﻿notes.txt")
    (click (role button :name "Upper"))
    (run-effect 1)
    (expect-text (test-id "outcome") "built ﻿notes.txt.upper:3:text/plain")
    (expect-text (test-id "built") "﻿notes.txt.upper:3:text/plain")
    (run-effect 2)
    (expect-text (test-id "preview") "ABC")))
