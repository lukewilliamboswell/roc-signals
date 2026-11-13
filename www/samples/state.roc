app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine exposing [Elem, In, Root, Signal, State]
import pf.Html

main : Engine.Program
main = Engine.program(signup)

# region contexts
## One domain transition per event: everything a submit changes is in one
## record.
Signup : { name : Str, email : Str, agreed : Bool, tried : Bool, sent : U64 }

## A separate concern gets a separate state: toggling compact mode never
## wakes anything that reads only the form.
C1 : In(Root, Signup)

C2 : In(C1, Bool)

# endregion contexts

# region states
signup : () -> Elem(Root)
signup = ||
	Engine.state(
		{ name: "", email: "", agreed: False, tried: False, sent: 0 },
		|form| Engine.state(False, |compact| page(form.lift(), compact)),
	)

# endregion states

# region problems
Problem : [NameMissing, EmailInvalid, NotAgreed]

problems : Signup -> List(Problem)
problems = |s|
	[]
		.concat(if (s.name.trim().is_empty()) [NameMissing] else [])
		.concat(if (s.email.contains("@")) [] else [EmailInvalid])
		.concat(if (s.agreed) [] else [NotAgreed])

message : Problem -> Str
message = |problem|
	match problem {
		NameMissing => "Enter your name."
		EmailInvalid => "Enter an email address with an @."
		NotAgreed => "Accept the terms to continue."
	}

## A submit marks the form as tried, and counts it as sent when it is valid.
submit : Signup -> Signup
submit = |s| if (problems(s).is_empty()) { ..s, tried: True, sent: s.sent + 1 } else { ..s, tried: True }

# endregion problems

# region page
page : State(C2, Signup), State(C2, Bool) -> Elem(C2)
page = |form, compact| {
	s = form.signal()
	shown = |p| s.map(|v| v.tried and problems(v).contains(p))
	Html.div_s(
		compact.signal().map(|c| if (c) "signup compact" else "signup"),
		[
			Html.checkbox(Engine.const("Compact"), compact.signal(), [], compact.set_value(|_, v| v == "true")),
			Html.form(
				"Sign up",
				[Html.on_submit(form.update(submit))],
				[
					Html.text_input(Engine.const("Name"), "text", s.map(|v| v.name), [Html.aria_invalid(shown(NameMissing))], form.set_value(|v, text| { ..v, name: text })),
					Html.text_input(Engine.const("Email"), "email", s.map(|v| v.email), [Html.aria_invalid(shown(EmailInvalid))], form.set_value(|v, text| { ..v, email: text })),
					Html.checkbox(Engine.const("I accept the terms"), s.map(|v| v.agreed), [], form.set_value(|v, flag| { ..v, agreed: flag == "true" })),
					Html.submit_button("Sign up", []),
				],
			),
			Html.p_s(s.map(|v| if (v.tried) Str.join_with(problems(v).map(message), " ") else ""), [Engine.test_id("problems")]),
			Html.p_s(s.map(|v| "Sent ${v.sent.to_str()} times"), [Engine.test_id("sent")]),
		],
	)
}

# endregion page

# region derive
## `derive` caches a signal of its own. Its body re-runs only when
## the derived value changes, so readers of `count` do no work on a keystroke
## that leaves the count the same.
word_count : State(C2, Signup) -> Elem(C2)
word_count = |form|
	Engine.derive(
		form.signal().map(|v| v.name.split_on(" ").count_if(|w| !w.is_empty())),
		|count| Html.p_s(count.map(|n| "${n.to_str()} words"), []),
	)

# endregion derive

# region map2
## Two signals combine with `map2`; the result reads both sources.
greeting : Signal(C2, Signup), Signal(C2, Bool) -> Signal(C2, Str)
greeting = |s, compact| Signal.map2(s, compact, |v, c| if (c) v.name else "Hello, ${v.name}")

# endregion map2

## The instance holds this store beside its site tree.
Store : {}

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
