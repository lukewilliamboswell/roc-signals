import pf.Engine
import pf.Html
import pf.Port
import CallView
import CommandView

Notifications := [].{
	# region declaration
	Permission : [Granted, Denied, Dismissed]

	## The module's named ports, declared once and registered together.
	Ports : {
		## Ask from the click's turn; the browser's permission result is data.
		permission : Port.Call({}, Permission),

		## Showing a notification is a command. A failure reaches onPortFault,
		## so an app that needs an acknowledgement instead declares a call.
		show : Port.Command({ title : Str, body : Str }),
	}

	## The same values serve requests and the derived program catalogue.
	ports : Ports
	ports = {
		permission: Port.call({ name: "example.org/recipes/notification-permission", timeout: Ms(60000) }),
		show: Port.command({ name: "example.org/recipes/notification-show" }),
	}
	# endregion declaration

	view : {} -> Engine.Elem(ctx)
	view = |_| Html.div(
		"recipe",
		[
			CallView.view({ label: "Allow notifications", test_id: "notification-result", port: Notifications.ports.permission, argument: Engine.const({}), show: Str.inspect }),
			CommandView.view({ label: "Show notification", port: Notifications.ports.show, argument: Engine.const({ title: "Roc Signals", body: "The page asked for this notification." }) }),
		],
	)
}
