import pf.Engine
import pf.Port
import CallView

ClipboardRead := [].{
	# region declaration
	## Reading needs browser permission. Writing uses the platform's Clipboard
	## module instead; this port only reads what the user chooses to allow.
	read : Port.Call({}, Str)
	read = Port.call({ name: "example.org/recipes/clipboard-read", timeout: Ms(15000) })
	# endregion declaration

	view : {} -> Engine.Elem(ctx)
	view = |_| CallView.view({ label: "Read clipboard", test_id: "clipboard-result", port: ClipboardRead.read, argument: Engine.const({}), show: |text| text })
}
