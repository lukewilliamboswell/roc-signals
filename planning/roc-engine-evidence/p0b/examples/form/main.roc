app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Action
import pf.Elem
import pf.Html
import pf.Signal
import pf.Ui

Form : { email : Str, password : Str, confirm : Str, attempted : Bool, submitted : U64 }

Problem := [MissingEmail, ShortPassword, Mismatch].{
	is_eq : _

	message : Problem -> Str
	message = |problem|
		match problem {
			MissingEmail => "Enter an email address."
			ShortPassword => "Use at least 8 characters."
			Mismatch => "Passwords do not match."
		}
}

problems : Form -> List(Problem)
problems = |form| {
	email = if form.email.is_empty() { [MissingEmail] } else { [] }
	short = if form.password.count_utf8_bytes() < 8 { [ShortPassword] } else { [] }
	mismatch = if form.password != form.confirm { [Mismatch] } else { [] }
	email.concat(short).concat(mismatch)
}

error_text : { form : Form, issues : List(Problem) } -> Str
error_text = |{ form, issues }|
	if form.attempted {
		Str.join_with(issues.map(Problem.message), " ")
	} else {
		""
	}

submit : Form -> Form
submit = |form|
	if problems(form).is_empty() {
		{ ..form, attempted: True, submitted: form.submitted + 1 }
	} else {
		{ ..form, attempted: True }
	}

field : Str, Signal(Str), Ui.Handler(Ui.Root) -> Elem(Ui.Root)
field = |label, value, on_input|
	Html.element("label", [], [Html.text(label), Html.text_input(label, value, on_input)])

main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		{ email: "", password: "", confirm: "", attempted: False, submitted: 0 },
		|form| {
			form_signal = form.signal()
			issues = form_signal.map(problems)
			## Record builder over independent site signals.
			error = { form: form_signal, issues }.Signal.map(error_text)
			cannot_submit = issues.map(|list| !list.is_empty())
			status = form_signal.map(|value| "Submitted ${value.submitted.to_str()} times")
			Html.element(
				"form",
				[Html.on_submit_prevent_default(Action.run(form_signal, |_| Action.update([form.write(submit)])))],
				[
					field("Email", form_signal.map(|value| value.email), form.update_str(|value, text| { ..value, email: text })),
					field("Password", form_signal.map(|value| value.password), form.update_str(|value, text| { ..value, password: text })),
					field("Confirm", form_signal.map(|value| value.confirm), form.update_str(|value, text| { ..value, confirm: text })),
					Html.element("p", [Html.class_attr("error"), Html.aria_invalid_s(cannot_submit)], [Html.text_s(error)]),
					Html.element("button", [Html.attr("type", "submit"), Html.disabled_s(cannot_submit)], [Html.text("Create account")]),
					Html.paragraph_s(status),
				],
			)
		},
	)
}

## The root description builds; each row template is described once, with holes.
expect {
	actual = Elem.platform_describe(main())
	actual == "<form:1><label:0>Email<input:3></input></label><label:0>Password<input:3></input></label><label:0>Confirm<input:3></input></label><p:2>{val}</p><button:2>Create account</button><p:0>{val}</p></form>"
}
