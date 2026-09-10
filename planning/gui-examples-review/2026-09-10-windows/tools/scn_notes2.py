from scn_common import *
s = start("notes-editor")
try:
    s.click(253, 134); d = dialog(s, "notes-win-save-as-untitled")
    if d: keys("escape"); time.sleep(0.8)
    s.click(113, 134); d = dialog(s, "notes-win-open-dialog-2", 5)
    if d: type_text(str(FIX / "Ideas.txt")); keys("enter"); time.sleep(1.5)
    s.click(253, 134); d = dialog(s, "notes-win-save-as-after-windows-open", 6)
    s.shot(OUT / "notes-win-after-save-as-click.png")
    print("windows now:", windows_of(s.process.pid), flush=True)
    if d: keys("escape"); time.sleep(0.5)
    s.keys("ctrl+shift+s"); d = dialog(s, "notes-win-ctrl-shift-s", 4)
    if d: keys("escape")
finally:
    finish(s, "notes2")
