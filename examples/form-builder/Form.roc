## The rules of the Form Builder, as plain data and pure functions.
##
## The app composes two levels of state:
##
##   * the *fields*: the definitions the designer edits, and
##   * the *answers*: the values a person types into the generated preview.
##
## Every validation result here is a pure function of a field and its
## answer, so the preview's verdicts, the totals and the "is this form
## submittable" flag are all read from those two, never written by an event.
##
## Nothing here knows how the form is held or drawn. A field is edited as a
## value, and a move is decided from a listing of the fields and answered
## as the keyed edits that make it: the app applies them to the table its
## store holds (`Schema`), and `fuzz-rules.roc` to a listing of its own.

Form := {}.{

	## The kind of control a field renders in the preview.
	Kind := [FieldText, FieldNumber, FieldEmail, FieldSelect, FieldCheckbox].{
		is_eq : _
	}

	## One field definition, as the form holds it under its number.
	##
	## `min_text` / `max_text` / `options_text` are stored exactly as typed. The
	## parsed rule is derived, never stored, so a half-typed or contradictory
	## rule is representable and reportable instead of silently dropped.
	##
	## `place` is where the field stands in the form's order: fields are
	## drawn from the lowest place to the highest, and a move exchanges the
	## places of two fields.
	Field : {
		kind : Form.Kind,
		label : Str,
		required : Bool,
		min_text : Str,
		max_text : Str,
		options_text : Str,
		place : U64,
	}

	## The form's fields by number, in no particular order: what a move is
	## decided from. A field's number is given once, when it is added, and
	## never to another field, so an answer can never reach the wrong one.
	Fields : List({ key : U64, row : Form.Field })

	## One keyed write to the fields: the definition to hold under a
	## number, or a number to drop. A move is a list of them, applied in
	## order.
	Edit : [Put(U64, Form.Field), Remove(U64)]

	## One answer typed into the preview form.
	Answer : {
		text : Str,
		flag : Bool,
	}

	## The preview's answers by field number. The map is sparse: a field
	## with no entry reads as empty and unchecked, and an entry left behind
	## by a deleted field is never looked up again.
	Answers : Dict(U64, Form.Answer)

	## A fully resolved preview row: the field, the answer bound to it, and the
	## validation verdict. This is the join of the two levels of state and the
	## only thing the preview's verdicts read.
	Row : {
		kind : Form.Kind,
		label : Str,
		required : Bool,
		options : List(Str),
		text : Str,
		flag : Bool,
		rule_error : Str,
		error : Str,
	}

	## A parsed numeric rule bound. `NoBound` is empty text, `BadBound` is text
	## that is present but not a whole number, and `HasBound` carries the value —
	## so "no bound" and "0" can never be confused for one another.
	Bound : [NoBound, BadBound, HasBound(I64)]

	## Human-readable name of a field kind, used in headings and default labels.
	kind_title : Form.Kind -> Str
	kind_title = |kind|
		match kind {
			FieldText => "Text"
			FieldNumber => "Number"
			FieldEmail => "Email"
			FieldSelect => "Select"
			FieldCheckbox => "Checkbox"
		}

	text_kind : Form.Kind
	text_kind = FieldText

	number_kind : Form.Kind
	number_kind = FieldNumber

	email_kind : Form.Kind
	email_kind = FieldEmail

	select_kind : Form.Kind
	select_kind = FieldSelect

	checkbox_kind : Form.Kind
	checkbox_kind = FieldCheckbox

	is_select : Form.Kind -> Bool
	is_select = |kind| match kind {
		FieldSelect => True
		_ => False
	}

	is_checkbox : Form.Kind -> Bool
	is_checkbox = |kind| match kind {
		FieldCheckbox => True
		_ => False
	}

	is_number : Form.Kind -> Bool
	is_number = |kind| match kind {
		FieldNumber => True
		_ => False
	}

	## Whether this kind is configured with min/max bounds rather than options.
	uses_bounds : Form.Kind -> Bool
	uses_bounds = |kind| !Form.is_select(kind)

	## The fields the example mounts with.
	initial_fields : Form.Fields
	initial_fields = [
		{
			key: 1,
			row: {
				kind: Form.text_kind,
				label: "Full name",
				required: True,
				min_text: "2",
				max_text: "",
				options_text: "",
				place: 1,
			},
		},
		{
			key: 2,
			row: {
				kind: Form.email_kind,
				label: "Work email",
				required: True,
				min_text: "",
				max_text: "",
				options_text: "",
				place: 2,
			},
		},
	]

	## The number the first field added to `initial_fields` takes.
	initial_next : U64
	initial_next = 3

	## No answers yet: every field reads as empty and unchecked.
	no_answers : Form.Answers
	no_answers = Dict.empty()

	# ---------------------------------------------------------------- field ops

	## The name a field's controls and regions carry: `f` and its number.
	id_of : U64 -> Str
	id_of = |number| "f${number.to_str()}"

	## The field a click on "Add" makes, for the number it is added under.
	## It stands last: numbers only grow, and a field starts at the place
	## of its number.
	new_field : Form.Kind, U64 -> Form.Field
	new_field = |kind, number| {
		kind,
		label: "${Form.kind_title(kind)} ${number.to_str()}",
		required: False,
		min_text: "",
		max_text: "",
		options_text: "",
		place: number,
	}

	set_label : Form.Field, Str -> Form.Field
	set_label = |field, value| { ..field, label: value }

	set_required : Form.Field, Bool -> Form.Field
	set_required = |field, value| { ..field, required: value }

	set_min : Form.Field, Str -> Form.Field
	set_min = |field, value| { ..field, min_text: value }

	set_max : Form.Field, Str -> Form.Field
	set_max = |field, value| { ..field, max_text: value }

	set_options : Form.Field, Str -> Form.Field
	set_options = |field, value| { ..field, options_text: value }

	## The edits that move a field one position earlier or later in the
	## form: it exchanges places with the field beside it on that side. The
	## first field cannot move earlier nor the last later, and a number the
	## form does not hold moves nothing: each is no edit.
	move_field : Form.Fields, { key : U64, toward : [Earlier, Later] } -> List(Form.Edit)
	move_field = |fields, { key, toward }|
		match fields.find_first(|held| held.key == key) {
			Ok(moving) =>
				match beside(fields, { place: moving.row.place, toward }) {
					Ok(other) => [Put(key, { ..moving.row, place: other.row.place }), Put(other.key, { ..other.row, place: moving.row.place })]
					Err(AtEnd) => []
				}
			Err(_) => []
		}

	## Where a field stands in the form's order: its place, then its
	## number. While the two edits of a move are applied one by one, two
	## fields stand at one place for a moment, and the number tells them
	## apart.
	Rank := { place : U64, key : U64 }.{
		is_eq : _

		## Fields at one position remain distinct by their authored key.
		order_relative_to : Rank, Rank -> [Before, Same, After]
		order_relative_to = |left, right| match left.place.order_relative_to(right.place) {
			Same => left.key.order_relative_to(right.key)
			other => other
		}
	}

	## How a view of the fields selects and orders them: every field, from
	## the lowest place to the highest.
	plan : {} -> { keep : U64, Form.Field -> Bool, sort : U64, Form.Field -> Form.Rank }
	plan = |{}| {
		keep: |_key, _field| True,
		sort: |key, field| { place: field.place, key },
	}

	## The fields' numbers in the form's order: what a view of them draws.
	ordered : Form.Fields -> List(U64)
	ordered = |fields| {
		{ sort, .. } = Form.plan({})
		fields.sort_with(|a, b| sort(a.key, a.row).order_relative_to(sort(b.key, b.row))).map(|held| held.key)
	}

	## A listing with `edits` applied in order, as the app's table applies
	## them: what a test or a model holds a move to.
	edited : Form.Fields, List(Form.Edit) -> Form.Fields
	edited = |fields, edits| edits.fold(
		fields,
		|held, edit| match edit {
			Put(key, field) => held.drop_if(|one| one.key == key).append({ key, row: field })
			Remove(key) => held.drop_if(|one| one.key == key)
		},
	)

	# --------------------------------------------------------------- answer ops

	## An answer no one has given: empty and unchecked.
	unanswered : Form.Answer
	unanswered = { text: "", flag: False }

	## The answer bound to the field numbered `key`: `unanswered` until the
	## preview holds one.
	answer_of : Form.Answers, U64 -> Form.Answer
	answer_of = |answers, key| answers.get(key) ?? Form.unanswered

	set_answer_text : Form.Answers, U64, Str -> Form.Answers
	set_answer_text = |answers, key, value| answers.update(
		key,
		|found| match found {
			Ok(answer) => Ok({ ..answer, text: value })
			Err(Missing) => Ok({ text: value, flag: False })
		},
	)

	set_answer_flag : Form.Answers, U64, Bool -> Form.Answers
	set_answer_flag = |answers, key, value| answers.update(
		key,
		|found| match found {
			Ok(answer) => Ok({ ..answer, flag: value })
			Err(Missing) => Ok({ text: "", flag: value })
		},
	)

	# ------------------------------------------------------------- text helpers

	## Comma-separated option list, trimmed, with blanks discarded.
	options_of : Str -> List(Str)
	options_of = |text|
		text.split_on(",").map(|part| part.trim()).keep_if(|part| !part.is_empty())

	contains_text : Str, Str -> Bool
	contains_text = |haystack, needle| haystack.split_on(needle).len() > 1

	## Length in bytes; the example's rules are documented in characters and the
	## example only ever uses ASCII input. An `I64`, as a field's bounds are.
	length_of : Str -> I64
	length_of = |text| text.to_utf8().len().to_i64_wrap()

	## Only plain decimal digits count as a number here. `I64.from_str` is more
	## generous than the rule syntax this example documents — it would accept
	## `"+5"` and `"1_0"` — so the digits are checked before it is asked.
	all_digits : Str -> Bool
	all_digits = |text| {
		bytes = text.to_utf8()
		!bytes.is_empty() and bytes.all(|byte| byte >= 48 and byte <= 57)
	}

	## Parse a rule bound. Empty text means "no bound"; anything that is not a
	## whole number is `BadBound`.
	bound_of : Str -> Form.Bound
	bound_of = |text| {
		trimmed = text.trim()
		if trimmed.is_empty() {
			NoBound
		} else {
			negative = trimmed.starts_with("-")
			digits = if negative {
				trimmed.drop_prefix("-")
			} else {
				trimmed
			}
			if Form.all_digits(digits) {
				match I64.from_str(trimmed) {
					Ok(value) => HasBound(value)
					Err(_) => BadBound
				}
			} else {
				BadBound
			}
		}
	}

	# --------------------------------------------------------------- validation

	## Problems with the *rule itself*, independent of any answer. A field with a
	## rule error can never be satisfied, so it blocks submission outright.
	rule_error : Form.Field -> Str
	rule_error = |field| {
		if Form.is_select(field.kind) {
			if Form.options_of(field.options_text).is_empty() {
				"Rule error: select has no options"
			} else {
				""
			}
		} else {
			match (Form.bound_of(field.min_text), Form.bound_of(field.max_text)) {
				(BadBound, _) => "Rule error: minimum is not a number"
				(_, BadBound) => "Rule error: maximum is not a number"
				(HasBound(min), HasBound(max)) =>
					if min > max {
						"Rule error: minimum is greater than maximum"
					} else {
						""
					}
				_ => ""
			}
		}
	}

	answer_error : Form.Field, Str, Bool -> Str
	answer_error = |field, text, flag| {
		trimmed = text.trim()
		match field.kind {
			FieldCheckbox =>
				if field.required and !flag {
					"Must be checked"
				} else {
					""
				}
			FieldSelect => {
				options = Form.options_of(field.options_text)
				if trimmed.is_empty() {
					if field.required {
						"Please choose an option"
					} else {
						""
					}
				} else if options.any(|option| option == trimmed) {
					""
				} else {
					"Choose one of the configured options"
				}
			}
			FieldNumber => {
				if trimmed.is_empty() {
					if field.required {
						"This field is required"
					} else {
						""
					}
				} else {
					match Form.bound_of(trimmed) {
						HasBound(value) => Form.range_error(field, value, "")
						_ => "Enter a whole number"
					}
				}
			}
			FieldEmail => {
				if trimmed.is_empty() {
					if field.required {
						"This field is required"
					} else {
						""
					}
				} else if Form.contains_text(trimmed, "@") and Form.contains_text(trimmed, ".") {
					Form.length_error(field, trimmed)
				} else {
					"Enter a valid email address"
				}
			}
			FieldText => {
				if trimmed.is_empty() {
					if field.required {
						"This field is required"
					} else {
						""
					}
				} else {
					Form.length_error(field, trimmed)
				}
			}
		}
	}

	length_error : Form.Field, Str -> Str
	length_error = |field, trimmed| Form.range_error(field, Form.length_of(trimmed), " characters")

	## Check one measured value against the field's own bounds. `unit` is the
	## word the message ends with: numbers are bare, text lengths are characters.
	range_error : Form.Field, I64, Str -> Str
	range_error = |field, value, unit| {
		below =
			match Form.bound_of(field.min_text) {
				HasBound(min) => if value < min {
					"Must be at least ${min.to_str()}${unit}"
				} else {
					""
				}
				_ => ""
			}
		if below != "" {
			below
		} else {
			match Form.bound_of(field.max_text) {
				HasBound(max) => if value > max {
					"Must be at most ${max.to_str()}${unit}"
				} else {
					""
				}
				_ => ""
			}
		}
	}

	## Join one field definition with its answer into a resolved preview row.
	row_of : Form.Field, Form.Answer -> Form.Row
	row_of = |field, { text, flag }| {
		rule = Form.rule_error(field)
		error = if rule == "" {
			Form.answer_error(field, text, flag)
		} else {
			rule
		}
		{
			kind: field.kind,
			label: field.label,
			required: field.required,
			options: Form.options_of(field.options_text),
			text,
			flag,
			rule_error: rule,
			error,
		}
	}

	## How many fields the form has, and how many of them hold a problem: a
	## broken rule or an unacceptable answer.
	Totals : { fields : U64, problems : U64 }

	## The totals of a form with no fields.
	empty_totals : Form.Totals
	empty_totals = { fields: 0, problems: 0 }

	## The totals with one more resolved row counted: the step of a fold
	## over the form's fields.
	counted : Form.Totals, Form.Row -> Form.Totals
	counted = |totals, row| { fields: totals.fields + 1, problems: if (row.error == "") totals.problems else totals.problems + 1 }

	## How many fields currently hold an acceptable answer.
	valid_count : Form.Totals -> U64
	valid_count = |totals| totals.fields - totals.problems

	## Whether the generated form can be submitted: every field holds an
	## acceptable answer. An empty form has nothing to submit, so it cannot.
	is_submittable : Form.Totals -> Bool
	is_submittable = |totals| totals.fields > 0 and totals.problems == 0

	## The note under a builder row's title: normally the field's own rule in one
	## word, and the rule error as soon as the rule contradicts itself.
	summary_text : Form.Field -> Str
	summary_text = |field| {
		rule = Form.rule_error(field)
		if rule == "" {
			if field.required {
				"Required"
			} else {
				"Optional"
			}
		} else {
			rule
		}
	}

	## Tone for that note. A broken rule is the designer's own mistake, so it is
	## red the moment it appears; a working rule is a neutral caption.
	summary_tone : Form.Field -> Str
	summary_tone = |field| if Form.rule_error(field) == "" {
		"hint"
	} else {
		"text-xs font-medium text-red-600"
	}

	## The badge tint for a field kind, so the same kind always reads the same
	## way in the builder list.
	kind_badge_class : Form.Kind -> Str
	kind_badge_class = |kind|
		match kind {
			FieldText => "badge badge-neutral"
			FieldNumber => "badge badge-info"
			FieldEmail => "badge badge-info"
			FieldSelect => "badge badge-warn"
			FieldCheckbox => "badge badge-neutral"
		}

	## Value text shown for the preview field, used by the row status line.
	##
	## The row's own `test_id` identifies which field this verdict belongs to, so
	## the text does not need to repeat the field label to stay locatable.
	verdict_text : Form.Row -> Str
	verdict_text = |row| if row.error == "" {
		"Valid"
	} else {
		row.error
	}

	## Tone for that verdict. An untouched field only states its requirement, so
	## it stays a neutral hint; it turns red once the answer is present and
	## unacceptable, or once the rule itself is broken.
	verdict_tone : Form.Row -> Str
	verdict_tone = |row|
		if row.error == "" {
			"text-xs font-medium text-emerald-700"
		} else if row.rule_error != "" {
			"text-xs font-medium text-red-600"
		} else if row.text.trim().is_empty() and !row.flag {
			"hint"
		} else {
			"text-xs font-medium text-red-600"
		}
}

## The field that stands nearest to `place` on the side `toward`.
beside : Form.Fields, { place : U64, toward : [Earlier, Later] } -> Try({ key : U64, row : Form.Field }, [AtEnd])
beside = |fields, { place, toward }| fields.fold(
	Err(AtEnd),
	|nearest, held| {
		is_on_side = match toward {
			Earlier => held.row.place < place
			Later => held.row.place > place
		}
		is_nearer = match nearest {
			Ok(found) =>
				match toward {
					Earlier => held.row.place > found.row.place
					Later => held.row.place < found.row.place
				}
			Err(AtEnd) => True
		}
		if (is_on_side and is_nearer) Ok(held) else nearest
	},
)

## Three fields in the order 1, 2, 3, for the tests below.
three : Form.Fields
three = [1, 2, 3].map(|number| { key: number, row: Form.new_field(Form.text_kind, number) })

## The starting form's fields stand in the order of their numbers.
expect Form.ordered(Form.initial_fields) == [1, 2]

## A new field is named for its kind and number, is optional, and stands last.
expect {
	added = Form.edited(Form.initial_fields, [Put(Form.initial_next, Form.new_field(Form.number_kind, Form.initial_next))])
	field = Form.new_field(Form.number_kind, 3)
	(Form.ordered(added), field.label, field.required, Form.id_of(3)) == ([1, 2, 3], "Number 3", False, "f3")
}

## Moving a field earlier exchanges it with the field before it, and writes no other field.
expect {
	edits = Form.move_field(three, { key: 3, toward: Earlier })
	(edits.len(), Form.ordered(Form.edited(three, edits))) == (2, [1, 3, 2])
}

## Moving a field later exchanges it with the field after it.
expect Form.ordered(Form.edited(three, Form.move_field(three, { key: 1, toward: Later }))) == [2, 1, 3]

## The first field cannot move earlier, the last cannot move later, and a number the form does not hold moves nothing.
expect {
	edits = [
		Form.move_field(three, { key: 1, toward: Earlier }),
		Form.move_field(three, { key: 3, toward: Later }),
		Form.move_field(three, { key: 9, toward: Earlier }),
	]
	edits == [[], [], []]
}

## A field moved twice the same way passes two fields, and deleting the one between leaves the order of the rest.
expect {
	once = Form.edited(three, Form.move_field(three, { key: 3, toward: Earlier }))
	twice = Form.edited(once, Form.move_field(once, { key: 3, toward: Earlier }))
	(Form.ordered(twice), Form.ordered(Form.edited(twice, [Remove(1)]))) == ([3, 1, 2], [3, 2])
}

## Two fields at one place are ordered by number, and a field is `Same` only as itself.
expect {
	compare = Form.Rank.order_relative_to
	orders = [
		compare({ place: 1, key: 9 }, { place: 2, key: 1 }),
		compare({ place: 2, key: 1 }, { place: 2, key: 3 }),
		compare({ place: 2, key: 3 }, { place: 2, key: 1 }),
		compare({ place: 2, key: 3 }, { place: 2, key: 3 }),
	]
	orders == [Before, Before, After, Same]
}

## A field with no answer reads as empty and unchecked, and an answer's text and flag are set apart.
expect {
	typed = Form.set_answer_text(Form.no_answers, 2, "Ada")
	checked = Form.set_answer_flag(typed, 2, True)
	retyped = Form.set_answer_text(checked, 2, "Grace")
	actual =
		\\unanswered: ${Str.inspect(Form.answer_of(typed, 1))}
		\\typed: ${Str.inspect(Form.answer_of(typed, 2))}
		\\checked: ${Str.inspect(Form.answer_of(checked, 2))}
		\\retyped: ${Str.inspect(Form.answer_of(retyped, 2))}
	expected =
		\\unanswered: { flag: False, text: "" }
		\\typed: { flag: False, text: "Ada" }
		\\checked: { flag: True, text: "Ada" }
		\\retyped: { flag: True, text: "Grace" }
	actual == expected
}

## A bound is no bound when blank, a whole number when it is one, and otherwise bad.
expect [Form.bound_of("  "), Form.bound_of(" 12 "), Form.bound_of("-3"), Form.bound_of("+5"), Form.bound_of("1_0"), Form.bound_of("abc")] == [NoBound, HasBound(12), HasBound(-3), BadBound, BadBound, BadBound]

## A rule that contradicts itself is reported for the field, whatever its answer.
expect {
	field = Form.set_max(Form.set_min(Form.new_field(Form.number_kind, 3), "20"), "10")
	row = Form.row_of(field, { text: "15", flag: False })
	(row.rule_error, row.error, Form.summary_text(field)) == ("Rule error: minimum is greater than maximum", "Rule error: minimum is greater than maximum", "Rule error: minimum is greater than maximum")
}

## A required text field refuses a blank answer and one shorter than its minimum, and accepts one within its bounds.
expect {
	field = Form.set_min(Form.set_required(Form.new_field(Form.text_kind, 1), True), "2")
	verdicts = ["  ", "A", "Ada"].map(|text| Form.verdict_text(Form.row_of(field, { text, flag: False })))
	verdicts == ["This field is required", "Must be at least 2 characters", "Valid"]
}

## A select with no options can never be answered, and one with options accepts only one of them.
expect {
	bare = Form.new_field(Form.select_kind, 4)
	sized = Form.set_options(bare, "Small, Large")
	verdicts = [
		Form.row_of(bare, Form.unanswered).error,
		Form.row_of(sized, Form.unanswered).error,
		Form.row_of(sized, { text: "Medium", flag: False }).error,
		Form.row_of(sized, { text: "Large", flag: False }).error,
	]
	verdicts == ["Rule error: select has no options", "", "Choose one of the configured options", ""]
}

## The totals count every field and those with a problem, and only a form with fields and no problem can be submitted.
expect {
	required = Form.set_required(Form.new_field(Form.text_kind, 1), True)
	blank = Form.counted(Form.empty_totals, Form.row_of(required, Form.unanswered))
	answered = Form.counted(Form.empty_totals, Form.row_of(required, { text: "Ada", flag: False }))
	actual =
		\\empty: ${Str.inspect(Form.is_submittable(Form.empty_totals))}
		\\blank: ${Str.inspect(blank)}, valid ${Form.valid_count(blank).to_str()}, submittable ${Str.inspect(Form.is_submittable(blank))}
		\\answered: ${Str.inspect(answered)}, valid ${Form.valid_count(answered).to_str()}, submittable ${Str.inspect(Form.is_submittable(answered))}
	expected =
		\\empty: False
		\\blank: { fields: 1, problems: 1 }, valid 0, submittable False
		\\answered: { fields: 1, problems: 0 }, valid 1, submittable True
	actual == expected
}
