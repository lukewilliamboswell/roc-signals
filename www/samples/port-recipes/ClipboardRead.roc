import pf.Engine
import pf.Port
import CallView

ClipboardRead := [].{
	# region declaration
	## The module's named ports, declared once and registered together.
	Ports : {
		## Reading needs browser permission. Writing uses the platform's Clipboard
		## module instead; this port only reads what the user chooses to allow.
		read : Port.Call({}, Str),
	}

	## The same values serve requests and the derived program catalogue.
	ports : Ports
	ports = {
		read: Port.call({ name: "example.org/recipes/clipboard-read", timeout: Ms(15000) }),
	}
	# endregion declaration

	view : {} -> Engine.Elem(ctx)
	view = |_| CallView.view({ label: "Read clipboard", test_id: "clipboard-result", port: ClipboardRead.ports.read, argument: Engine.const({}), show: |text| text })
}
