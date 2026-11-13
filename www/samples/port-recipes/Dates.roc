import pf.Engine
import pf.Port
import CallView

Dates := [].{
	# region declaration
	Input : { languages : List(Str), zone : Str, instants : List(I64) }

	## The module's named ports, declared once and registered together.
	Ports : {
		## Format one batch with browser CLDR data. Milliseconds cross as decimal
		## strings; a date outside the browser's range is a failure, never rounded.
		format : Port.Call(Input, List(Str)),
	}

	## The same values serve requests and the derived program catalogue.
	ports : Ports
	ports = {
		format: Port.call({ name: "example.org/recipes/format-dates", timeout: Ms(5000) }),
	}
	# endregion declaration

	## Choosing UTC for an unknown zone name is this sample's explicit rule.
	## A hole displays the answered strings; it never calls Intl synchronously.
	view : { now_ms : I64, languages : List(Str), zone : Str } -> Engine.Elem(ctx)
	view = |facts| CallView.view({ label: "Format dates", test_id: "dates-result", port: Dates.ports.format, argument: Engine.const({ languages: facts.languages, zone: if (facts.zone.is_empty()) "UTC" else facts.zone, instants: [facts.now_ms, 0] }), show: |dates| Str.join_with(dates, " | ") })
}
