(test "A CRLF file with a byte-order mark opens as plain lines and counts them once"
  (steps
    (stub-file-choice "notes-open" (chosen "/tmp/Ideas.txt"))
    ; The fixture carries a real U+FEFF before its first byte.
    (stub-file-read "notes-read" :path "/tmp/Ideas.txt" :text "﻿First idea\r\nSecond idea\r\n")
    (shortcut (test-id "notes-editor") "o" 1)
    (expect-value (label "Note text") "First idea\nSecond idea\n")
    (expect-text (test-id "note-summary") "4 words · 23 characters")
    (expect-text (test-id "note-status") "No changes")
    (fill (label "Note text") "First idea\nSecond idea\nThird idea\n")
    (expect-text (test-id "note-status") "Unsaved changes")
    (shortcut (test-id "notes-editor") "s" 1)
    (expect-text (test-id "note-status") "No changes")
    (expect-value (label "Note text") "First idea\nSecond idea\nThird idea\n")
))
