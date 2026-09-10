(test "Windows breadcrumbs include the actual parent directory"
  (steps
    (click (role button :name "Choose folder"))
    (resolve-task "folder-choice" "6:files16:chosen12:C:\\Users\\Lee")
    (resolve-task "folder-list" "6:files112:C:\\Users\\Lee1:0")
    (expect-visible (label "Go to C:\\Users"))))
