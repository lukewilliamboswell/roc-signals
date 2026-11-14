(test "Markdown editor — copy as markdown and html"
  (steps
    (fill (label "Markdown source") "# Doc\n\nUse **bold** & <literal>.")
    (click (role button :name "Copy as markdown"))
    (expect-clipboard "# Doc\n\nUse **bold** & <literal>.")
    (expect-clipboard-writes 1)
    (expect-text (test-id "copy-status") "Copied")
    (click (role button :name "Copy as HTML"))
    (expect-clipboard "# Doc\n\nUse **bold** & <literal>.")
    (expect-clipboard-html "<h1>Doc</h1>\n<p>Use <strong>bold</strong> &amp; &lt;literal&gt;.</p>")
    (expect-clipboard-writes 2)
    (expect-text (test-id "copy-status") "Copied"))
)
