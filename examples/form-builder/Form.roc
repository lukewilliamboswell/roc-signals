## Domain layer for the Form Builder example.
##
## This module owns the two levels of state the app composes:
##
##   * the *schema* — the field definitions the designer edits, and
##   * the *answers* — the values a person types into the generated preview.
##
## Both are plain data. Every validation result in this module is a pure
## function of those two inputs, so the app can express the entire preview,
## including per-field errors and the "is this form submittable" flag, as
## derived signals rather than as state written by event handlers.
import pf.Signal

Form := {}.{

	## The kind of control a field renders in the preview.
	Kind := [FieldText, FieldNumber, FieldEmail, FieldSelect, FieldCheckbox].{
		is_eq : Form.Kind, Form.Kind -> Bool
		is_eq = |left, right|
			match (left, right) {
				(FieldText, FieldText) => True
				(FieldNumber, FieldNumber) => True
				(FieldEmail, FieldEmail) => True
				(FieldSelect, FieldSelect) => True
				(FieldCheckbox, FieldCheckbox) => True
				_ => False
			}
	}

	## One field definition in the designer.
	##
	## `min_text` / `max_text` / `options_text` are stored exactly as typed. The
	## parsed rule is derived, never stored, so a half-typed or contradictory
	## rule is representable and reportable instead of silently dropped.
	Field : {
		id : Str,
		kind : Form.Kind,
		label : Str,
		required : Bool,
		min_text : Str,
		max_text : Str,
		options_text : Str,
	}

	## The designer's state: the field list plus the id counter used to mint
	## stable, durable keys for `Ui.each_str`.
	Schema : {
		fields : List(Form.Field),
		seq : U64,
	}

	## One answer typed into the preview form. Answers are a sparse map keyed by
	## field id: fields with no entry read as empty/unchecked, and entries left
	## behind by a deleted field are simply never looked up again.
	Answer : {
		id : Str,
		text : Str,
		flag : Bool,
	}

	## A fully resolved preview row: the field, the answer bound to it, and the
	## validation verdict. This is the join of the two levels of state and the
	## only thing the preview UI ever reads.
	Row : {
		id : Str,
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
	is_select = |kind| match kind { FieldSelect => True, _ => False }

	is_checkbox : Form.Kind -> Bool
	is_checkbox = |kind| match kind { FieldCheckbox => True, _ => False }

	is_number : Form.Kind -> Bool
	is_number = |kind| match kind { FieldNumber => True, _ => False }

	## Whether this kind is configured with min/max bounds rather than options.
	uses_bounds : Form.Kind -> Bool
	uses_bounds = |kind| !Form.is_select(kind)

	## The schema the example mounts with.
	initial_schema : Form.Schema
	initial_schema = {
		seq: 2,
		fields: [
			{
				id: "f1",
				kind: Form.text_kind,
				label: "Full name",
				required: True,
				min_text: "2",
				max_text: "",
				options_text: "",
			},
			{
				id: "f2",
				kind: Form.email_kind,
				label: "Work email",
				required: True,
				min_text: "",
				max_text: "",
				options_text: "",
			},
		],
	}

	initial_answers : List(Form.Answer)
	initial_answers = []

	# ---------------------------------------------------------------- schema ops

	## Append a new field of `kind`, minting the next durable id.
	add_field : Form.Schema, Form.Kind -> Form.Schema
	add_field = |schema, kind| {
		next = schema.seq + 1
		field : Form.Field
		field = {
			id: "f${next.to_str()}",
			kind,
			label: "${Form.kind_title(kind)} ${next.to_str()}",
			required: False,
			min_text: "",
			max_text: "",
			options_text: "",
		}
		{ seq: next, fields: schema.fields.append(field) }
	}

	update_field : Form.Schema, Str, (Form.Field -> Form.Field) -> Form.Schema
	update_field = |schema, id, f|
		{ ..schema, fields: schema.fields.map(|field| if field.id == id { f(field) } else { field }) }

	set_label : Form.Schema, Str, Str -> Form.Schema
	set_label = |schema, id, value| Form.update_field(schema, id, |field| { ..field, label: value })

	set_required : Form.Schema, Str, Bool -> Form.Schema
	set_required = |schema, id, value| Form.update_field(schema, id, |field| { ..field, required: value })

	set_min : Form.Schema, Str, Str -> Form.Schema
	set_min = |schema, id, value| Form.update_field(schema, id, |field| { ..field, min_text: value })

	set_max : Form.Schema, Str, Str -> Form.Schema
	set_max = |schema, id, value| Form.update_field(schema, id, |field| { ..field, max_text: value })

	set_options : Form.Schema, Str, Str -> Form.Schema
	set_options = |schema, id, value| Form.update_field(schema, id, |field| { ..field, options_text: value })

	delete_field : Form.Schema, Str -> Form.Schema
	delete_field = |schema, id|
		{ ..schema, fields: schema.fields.keep_if(|field| field.id != id) }

	## Move the field with `id` one position earlier. The fold carries the
	## previous element so the swap needs no index arithmetic.
	move_up : Form.Schema, Str -> Form.Schema
	move_up = |schema, id| {
		folded =
			schema.fields.fold(
				{ out: [], prev: [] },
				|acc, field| {
					if field.id == id and !acc.prev.is_empty() {
						{ out: acc.out.append(field).concat(acc.prev), prev: [] }
					} else {
						{ out: acc.out.concat(acc.prev), prev: [field] }
					}
				},
			)
		{ ..schema, fields: folded.out.concat(folded.prev) }
	}

	## Move the field with `id` one position later, by mirroring `move_up`.
	move_down : Form.Schema, Str -> Form.Schema
	move_down = |schema, id| {
		reversed = { ..schema, fields: Form.reverse(schema.fields) }
		moved = Form.move_up(reversed, id)
		{ ..schema, fields: Form.reverse(moved.fields) }
	}

	reverse : List(Form.Field) -> List(Form.Field)
	reverse = |fields| fields.fold([], |acc, field| [field].concat(acc))

	# --------------------------------------------------------------- answer ops

	## The answer bound to `id`, if the preview has one yet.
	find_answer : List(Form.Answer), Str -> Try(Form.Answer, [NotFound])
	find_answer = |answers, id| answers.find_first(|answer| answer.id == id)

	answer_text : List(Form.Answer), Str -> Str
	answer_text = |answers, id|
		Form.find_answer(answers, id).map_ok(|answer| answer.text) ?? ""

	answer_flag : List(Form.Answer), Str -> Bool
	answer_flag = |answers, id|
		Form.find_answer(answers, id).map_ok(|answer| answer.flag) ?? False

	set_answer_text : List(Form.Answer), Str, Str -> List(Form.Answer)
	set_answer_text = |answers, id, value|
		if Form.find_answer(answers, id).is_ok() {
			answers.map(|answer| if answer.id == id { { ..answer, text: value } } else { answer })
		} else {
			answers.append({ id, text: value, flag: False })
		}

	set_answer_flag : List(Form.Answer), Str, Bool -> List(Form.Answer)
	set_answer_flag = |answers, id, value|
		if Form.find_answer(answers, id).is_ok() {
			answers.map(|answer| if answer.id == id { { ..answer, flag: value } } else { answer })
		} else {
			answers.append({ id, text: "", flag: value })
		}

	# ------------------------------------------------------------- text helpers

	## Comma-separated option list, trimmed, with blanks discarded.
	options_of : Str -> List(Str)
	options_of = |text|
		text.split_on(",").map(|part| part.trim()).keep_if(|part| !part.is_empty())

	contains_text : Str, Str -> Bool
	contains_text = |haystack, needle| haystack.split_on(needle).len() > 1

	## Length in bytes; the example's rules are documented in characters and the
	## example only ever uses ASCII input. Counted with a fold because this Roc
	## build exposes no `U64 -> I64` conversion.
	length_of : Str -> I64
	length_of = |text| text.to_utf8().fold(0, |acc, _byte| acc + 1)

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
			digits = if negative { trimmed.drop_prefix("-") } else { trimmed }
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
					if min > max { "Rule error: minimum is greater than maximum" } else { "" }
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
				HasBound(min) => if value < min { "Must be at least ${min.to_str()}${unit}" } else { "" }
				_ => ""
			}
		if below != "" {
			below
		} else {
			match Form.bound_of(field.max_text) {
				HasBound(max) => if value > max { "Must be at most ${max.to_str()}${unit}" } else { "" }
				_ => ""
			}
		}
	}

	## Join one field definition with its answer into a resolved preview row.
	row_of : Form.Field, List(Form.Answer) -> Form.Row
	row_of = |field, answers| {
		text = Form.answer_text(answers, field.id)
		flag = Form.answer_flag(answers, field.id)
		rule = Form.rule_error(field)
		error = if rule == "" { Form.answer_error(field, text, flag) } else { rule }
		{
			id: field.id,
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

	## The join of the two levels of state: schema x answers -> preview rows.
	rows_of : List(Form.Field), List(Form.Answer) -> List(Form.Row)
	rows_of = |fields, answers| fields.map(|field| Form.row_of(field, answers))

	problem_count : List(Form.Row) -> U64
	problem_count = |rows| rows.keep_if(|row| row.error != "").len()

	all_valid : List(Form.Row) -> Bool
	all_valid = |rows| Form.problem_count(rows) == 0

	## How many rows currently hold an acceptable answer.
	valid_count : List(Form.Row) -> U64
	valid_count = |rows| rows.len() - Form.problem_count(rows)

	## The note under a builder row's title: normally the field's own rule in one
	## word, and the rule error as soon as the rule contradicts itself.
	summary_text : Form.Field -> Str
	summary_text = |field| {
		rule = Form.rule_error(field)
		if rule == "" {
			if field.required { "Required" } else { "Optional" }
		} else {
			rule
		}
	}

	## Tone for that note. A broken rule is the designer's own mistake, so it is
	## red the moment it appears; a working rule is a neutral caption.
	summary_tone : Form.Field -> Str
	summary_tone = |field| if Form.rule_error(field) == "" { "hint" } else { "text-xs font-medium text-red-600" }

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
	verdict_text = |row| if row.error == "" { "Valid" } else { row.error }

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

	# ------------------------------------------------------------ signal lenses

	field_label : Signal.Signal(Form.Field) -> Signal.Signal(Str)
	field_label = |field| field.map(|value| value.label)

	row_text : Signal.Signal(Form.Row) -> Signal.Signal(Str)
	row_text = |row| row.map(|value| value.text)
}
