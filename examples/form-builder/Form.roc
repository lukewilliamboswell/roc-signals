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
		is_eq = |left, right| Form.kind_code(left) == Form.kind_code(right)
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

	## A parsed numeric rule bound. `set` distinguishes "no bound" from "0", and
	## `bad` marks text that is present but not a number.
	Bound : {
		set : Bool,
		bad : Bool,
		value : I64,
	}

	kind_code : Form.Kind -> U64
	kind_code = |kind|
		match kind {
			FieldText => 0
			FieldNumber => 1
			FieldEmail => 2
			FieldSelect => 3
			FieldCheckbox => 4
		}

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
	is_select = |kind| Form.kind_code(kind) == 3

	is_checkbox : Form.Kind -> Bool
	is_checkbox = |kind| Form.kind_code(kind) == 4

	is_number : Form.Kind -> Bool
	is_number = |kind| Form.kind_code(kind) == 1

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
	delete_field = |schema, id| {
		kept = schema.fields.fold([], |acc, field| if field.id == id { acc } else { acc.append(field) })
		{ ..schema, fields: kept }
	}

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

	answer_text : List(Form.Answer), Str -> Str
	answer_text = |answers, id|
		answers.fold("", |acc, answer| if answer.id == id { answer.text } else { acc })

	answer_flag : List(Form.Answer), Str -> Bool
	answer_flag = |answers, id|
		answers.fold(False, |acc, answer| if answer.id == id { answer.flag } else { acc })

	set_answer_text : List(Form.Answer), Str, Str -> List(Form.Answer)
	set_answer_text = |answers, id, value| {
		found = answers.fold(False, |acc, answer| if answer.id == id { True } else { acc })
		if found {
			answers.map(|answer| if answer.id == id { { ..answer, text: value } } else { answer })
		} else {
			answers.append({ id, text: value, flag: False })
		}
	}

	set_answer_flag : List(Form.Answer), Str, Bool -> List(Form.Answer)
	set_answer_flag = |answers, id, value| {
		found = answers.fold(False, |acc, answer| if answer.id == id { True } else { acc })
		if found {
			answers.map(|answer| if answer.id == id { { ..answer, flag: value } } else { answer })
		} else {
			answers.append({ id, text: "", flag: value })
		}
	}

	# ------------------------------------------------------------- text helpers

	## Comma-separated option list, trimmed, with blanks discarded.
	options_of : Str -> List(Str)
	options_of = |text|
		text.split_on(",").fold(
			[],
			|acc, part| {
				trimmed = part.trim()
				if trimmed.is_empty() {
					acc
				} else {
					acc.append(trimmed)
				}
			},
		)

	contains_text : Str, Str -> Bool
	contains_text = |haystack, needle| haystack.split_on(needle).len() > 1

	## Length in bytes; the example's rules are documented in characters and the
	## example only ever uses ASCII input. Counted with a fold because this Roc
	## build exposes no `U64 -> I64` conversion.
	length_of : Str -> I64
	length_of = |text| text.to_utf8().fold(0, |acc, _byte| acc + 1)

	## Decimal digit byte to `I64`, written out because this Roc build exposes no
	## `U8 -> I64` conversion.
	digit_value : U8 -> I64
	digit_value = |byte|
		if byte == 49 {
			1
		} else if byte == 50 {
			2
		} else if byte == 51 {
			3
		} else if byte == 52 {
			4
		} else if byte == 53 {
			5
		} else if byte == 54 {
			6
		} else if byte == 55 {
			7
		} else if byte == 56 {
			8
		} else if byte == 57 {
			9
		} else {
			0
		}

	## Parse a rule bound. Empty text means "no bound"; unparsable text is `bad`.
	bound_of : Str -> Form.Bound
	bound_of = |text| {
		trimmed = text.trim()
		if trimmed.is_empty() {
			{ set: False, bad: False, value: 0 }
		} else {
			negative = trimmed.starts_with("-")
			digits = if negative { trimmed.drop_prefix("-") } else { trimmed }
			bytes = digits.to_utf8()
			if bytes.is_empty() {
				{ set: True, bad: True, value: 0 }
			} else {
				folded =
					bytes.fold(
						{ ok: True, value: 0 },
						|acc, byte| {
							if acc.ok and byte >= 48 and byte <= 57 {
								{ ok: True, value: acc.value * 10 + Form.digit_value(byte) }
							} else {
								{ ok: False, value: 0 }
							}
						},
					)
				if !folded.ok {
					{ set: True, bad: True, value: 0 }
				} else if negative {
					{ set: True, bad: False, value: 0 - folded.value }
				} else {
					{ set: True, bad: False, value: folded.value }
				}
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
			min = Form.bound_of(field.min_text)
			max = Form.bound_of(field.max_text)
			if min.bad {
				"Rule error: minimum is not a number"
			} else if max.bad {
				"Rule error: maximum is not a number"
			} else if min.set and max.set and min.value > max.value {
				"Rule error: minimum is greater than maximum"
			} else {
				""
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
				} else if options.fold(False, |acc, option| acc or option == trimmed) {
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
					parsed = Form.bound_of(trimmed)
					min = Form.bound_of(field.min_text)
					max = Form.bound_of(field.max_text)
					if parsed.bad {
						"Enter a whole number"
					} else if min.set and parsed.value < min.value {
						"Must be at least ${min.value.to_str()}"
					} else if max.set and parsed.value > max.value {
						"Must be at most ${max.value.to_str()}"
					} else {
						""
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
	length_error = |field, trimmed| {
		min = Form.bound_of(field.min_text)
		max = Form.bound_of(field.max_text)
		length = Form.length_of(trimmed)
		if min.set and length < min.value {
			"Must be at least ${min.value.to_str()} characters"
		} else if max.set and length > max.value {
			"Must be at most ${max.value.to_str()} characters"
		} else {
			""
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
	problem_count = |rows| rows.fold(0, |acc, row| if row.error == "" { acc } else { acc + 1 })

	all_valid : List(Form.Row) -> Bool
	all_valid = |rows| Form.problem_count(rows) == 0

	## Status line for the preview: field count plus outstanding problems.
	status_text : List(Form.Row) -> Str
	status_text = |rows| {
		count = rows.len()
		problems = Form.problem_count(rows)
		fields_part = if count == 1 { "1 field" } else { "${count.to_str()} fields" }
		problems_part = if problems == 1 { "1 problem" } else { "${problems.to_str()} problems" }
		"Preview status: ${fields_part}, ${problems_part}"
	}

	## Field summary line shown in each builder row.
	summary_text : Form.Field -> Str
	summary_text = |field| {
		required_part = if field.required { "required" } else { "optional" }
		rule = Form.rule_error(field)
		base = "${field.label} field: ${Form.kind_title(field.kind)} - ${required_part}"
		if rule == "" {
			base
		} else {
			"${base} - ${rule}"
		}
	}

	## Value text shown for the preview field, used by the row status line.
	##
	## The row's own `test_id` identifies which field this verdict belongs to, so
	## the text does not need to repeat the field label to stay locatable.
	verdict_text : Form.Row -> Str
	verdict_text = |row| if row.error == "" { "Valid" } else { row.error }

	# ------------------------------------------------------------ signal lenses

	field_label : Signal.Signal(Form.Field) -> Signal.Signal(Str)
	field_label = |field| field.map(|value| value.label)

	row_text : Signal.Signal(Form.Row) -> Signal.Signal(Str)
	row_text = |row| row.map(|value| value.text)
}
