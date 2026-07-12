app [main] { pf: platform "./platform/main.roc" }

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Plan := [Team, Basic]
TextDraft := [TextUntouched, TextChanged(Str)]
PlanDraft := [PlanUntouched, PlanChanged(Plan)]

decode_plan = |value| if value == "basic" { Plan.Basic } else { Plan.Team }

stored_text = |fallback, stored|
	match stored { StorageValue(value) => value, _ => fallback }

stored_plan = |fallback, stored|
	match stored { StorageValue(value) => decode_plan(value), _ => fallback }

encode_plan = |plan|
	match plan { Plan.Team => "team", Plan.Basic => "basic" }

draft_text_value = |fallback, draft, stored|
	match draft {
		TextChanged(value) => value
		TextUntouched => stored_text(fallback, stored)
	}

draft_plan_value = |fallback, draft, stored|
	match draft {
		PlanChanged(value) => value
		PlanUntouched => stored_plan(fallback, stored)
	}

draft_text_signal = |fallback, draft, stored| {
	inputs = { draft: draft, stored: stored }.Signal
	inputs.map(|value| draft_text_value(fallback, value.draft, value.stored))
}

draft_plan_signal = |fallback, draft, stored| {
	inputs = { draft: draft, stored: stored }.Signal
	inputs.map(|value| draft_plan_value(fallback, value.draft, value.stored))
}

email_key = "email"
plan_key = "plan"

main : () -> Elem
main = || {
	stored_email = Browser.local_storage_text(email_key)
	stored_plan_source = Browser.local_storage_text(plan_key)

	Ui.state(TextUntouched, |email|
		Ui.state(PlanUntouched, |plan| {
			email_value = draft_text_signal("", email.signal(), stored_email)
			plan_value = draft_plan_signal(Plan.Team, plan.signal(), stored_plan_source)

			Html.div_c("", [
				Ui.on_change(email_value, |value| Browser.set_local_storage_text(email_key, value)),
				Ui.on_change(plan_value, |value| Browser.set_local_storage_text(plan_key, encode_plan(value))),
			])
		})
	)
}
