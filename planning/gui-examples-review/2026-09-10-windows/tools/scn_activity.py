from scn_common import *
s = start("activity-monitor")
try:
    s.click(70, 183); d = dialog(s, "activity-win-open-log-dialog")
    if d: type_text(str(FIX / "app.log")); keys("enter"); time.sleep(2.0)
    s.shot(OUT / "activity-win-log-opened.png")
    with open(FIX / "app.log", "ab") as f:
        f.write(b"2026-09-10T10:00:03Z INFO appended while app follows the file\r\n")
    time.sleep(3.0); s.shot(OUT / "activity-win-log-appended.png")
    try:
        os.replace(FIX / "app.log", FIX / "app.log.moved"); print("rename while followed: ok"); os.replace(FIX / "app.log.moved", FIX / "app.log")
    except OSError as e:
        print("rename while followed failed:", e)
    s.click(462, 183); time.sleep(1.0); s.shot(OUT / "activity-win-after-cancel.png")
    s.click(341, 183); time.sleep(2.0); s.shot(OUT / "activity-win-after-retry.png")
    s.click(206, 183); time.sleep(1.0); s.click(176, 270); s.click(176, 270); s.click(176, 270); time.sleep(0.5); s.shot(OUT / "activity-win-replay-3-steps.png")
finally:
    finish(s, "activity")
