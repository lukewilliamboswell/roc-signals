import pf.Engine
import pf.Port
import CallView

Share := [].{
	# region declaration
	Answer : [Shared, Cancelled]

	## The OS share sheet needs the user's gesture. Cancellation is an answer,
	## while denial or an unavailable service remains a typed port failure.
	share : Port.Call({ title : Str, text : Str, url : Str }, Answer)
	share = Port.call({ name: "example.org/recipes/share", timeout: Ms(60000) })
	# endregion declaration

	view : {} -> Engine.Elem(ctx)
	view = |_| CallView.view({ label: "Share", test_id: "share-result", port: Share.share, argument: Engine.const({ title: "Roc Signals", text: "A pure engine and a browser host.", url: "https://lukewilliamboswell.github.io/roc-signals/" }), show: Str.inspect })
}
