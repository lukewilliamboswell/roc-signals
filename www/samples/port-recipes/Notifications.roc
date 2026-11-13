import pf.Engine
import pf.Html
import pf.Port
import CallView
import CommandView

Notifications := [].{
	# region declaration
	Permission : [Granted, Denied, Dismissed]

	## Ask from the click's turn; the browser's permission result is data.
	permission : Port.Call({}, Permission)
	permission = Port.call({ name: "example.org/recipes/notification-permission", timeout: Ms(60000) })

	## Showing a notification is a command. A failure reaches onPortFault,
	## so an app that needs an acknowledgement instead declares a call.
	show : Port.Command({ title : Str, body : Str })
	show = Port.command({ name: "example.org/recipes/notification-show" })
	# endregion declaration

	view : {} -> Engine.Elem(ctx)
	view = |_| Html.div(
		"recipe",
		[
			CallView.view({ label: "Allow notifications", test_id: "notification-result", port: Notifications.permission, argument: Engine.const({}), show: Str.inspect }),
			CommandView.view({ label: "Show notification", port: Notifications.show, argument: Engine.const({ title: "Roc Signals", body: "The page asked for this notification." }) }),
		],
	)
}
