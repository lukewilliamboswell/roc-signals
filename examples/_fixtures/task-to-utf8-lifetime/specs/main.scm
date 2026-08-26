(test "Task to utf8 lifetime"
  (steps
    ; HTTP text task results own decoded UTF-8 beyond the response envelope lifetime.

    (expect-visible (role heading :name "Task UTF-8 lifetime"))
    (expect-visible (text "loading"))
    (expect-pending-task "http:send:dashboard" 1)
    (resolve-task "http:send:dashboard" "roc-http-response-v1\n200\n0\n82,111,99,32,116,97,115,107,32,98,111,100,121,32,119,105,116,104,32,85,84,70,45,56,32,112,97,121,108,111,97,100,58,32,99,97,102,195,169,32,240,159,154,128,32,115,116,97,121,115,32,111,119,110,101,100")
    (expect-pending-task "http:send:dashboard" 0)
    (expect-visible (text "ready bytes 56"))
  )
)
