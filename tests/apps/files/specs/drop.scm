(test "Files — files dropped on a drop target, or pasted, arrive as handles"
  (setup
    (file "photo.png" "image/png" "png!")
    (file "readme.md" "text/markdown" "# readme"))
  (steps
    (drop-files (label "Drop") "photo.png" "readme.md")
    (expect-text (test-id "files") "photo.png:4:image/png|readme.md:8:text/markdown")
    (paste-files (label "Paste") "photo.png")
    (expect-text (test-id "files") "photo.png:4:image/png|readme.md:8:text/markdown|photo.png:4:image/png")
    (expect-files 3)
  )
)
