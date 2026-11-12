app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
}

import fz.Fuzz
import Form

## The form builder's schema edits and its validation, against a model.
## The designer keeps the fields as one list it edits in place and moves by
## folding, and the preview parses each rule's bounds from the text the
## designer typed, so the bugs to fear are a field lost, doubled or moved
## too far, and an answer judged against a bound that was read wrongly.
##
## Each input decodes into a sequence of designer steps (add a field of any
## kind, delete one, move one up or down, type its minimum or maximum,
## toggle it required, type an answer) from pieces that include signs,
## spaces, `+`, `_` and numbers too large for a bound. After every step:
##
## - the fields are the model's, in its order, and their ids are distinct;
## - a bound is no bound when blank, a whole number when it is one (an
##   optional `-` and decimal digits that fit), and otherwise a rule error;
## - a number or text field whose rule is sound accepts exactly a blank
##   answer when it is not required, or a whole number (a length, for
##   text) within its bounds;
## - the count of problems is the count of rows with an error.
Input : List(U8)

## The pieces a bound or an answer is typed from; an input byte picks one.
pieces : List(Str)
pieces = ["", "0", "7", "-3", " 12 ", "+5", "1_0", "99999999999999999999", "abc", "-", "x@y.z", "5", "-0"]

## The model's bound, or a rule error.
model_bound : Str -> [None, Whole(I128), Unsound]
model_bound = |text| {
	t = text.trim()
	if t.is_empty() {
		return None
	}
	(sign, digits) = if (t.starts_with("-")) (-1, t.drop_prefix("-").to_utf8()) else (1, t.to_utf8())
	if digits.is_empty() or digits.any(|d| d < '0' or d > '9') or digits.len() > 19 {
		return Unsound
	}
	value = sign * digits.fold(0.I128, |acc, d| acc * 10 + (d - '0').to_i128())
	if value > 9_223_372_036_854_775_807 or value < -9_223_372_036_854_775_808 {
		Unsound
	} else {
		Whole(value)
	}
}

## The model's verdict on a number or text field's answer, when its rule
## is sound.
accepts : Form.Field, Str -> [Sound(Bool), Unsound]
accepts = |field, text| {
	match (model_bound(field.min_text), model_bound(field.max_text)) {
		(Unsound, _) | (_, Unsound) => Unsound
		(Whole(lo), Whole(hi)) if lo > hi => Unsound
		(lo, hi) => {
			within = |n|
				(
					match lo {
						Whole(m) => n >= m
						_ => Bool.True
					}
				) and (
					match hi {
						Whole(m) => n <= m
						_ => Bool.True
					}
				)
			t = text.trim()
			if t.is_empty() {
				Sound(!field.required)
			} else if Form.is_number(field.kind) {
				match model_bound(t) {
					Whole(n) => Sound(within(n))
					_ => Sound(Bool.False)
				}
			} else {
				Sound(within(t.to_utf8().len().to_i128()))
			}
		}
	}
}

## One step of the designer, from three bytes.
step : (Form.Schema, List(Form.Answer)), U8, U8, U8 -> (Form.Schema, List(Form.Answer))
step = |(schema, answers), op, a, b| {
	id = (schema.fields.get(a.to_u64() % (schema.fields.len() + 1)) ?? Form.prev_placeholder).id
	text = pieces.get(b.to_u64() % pieces.len()) ?? ""
	match op % 8 {
		0 => (Form.add_field(schema, if (b % 2 == 0) Form.number_kind else Form.text_kind), answers)
		1 => (Form.delete_field(schema, id), answers)
		2 => (Form.move_up(schema, id), answers)
		3 => (Form.move_down(schema, id), answers)
		4 => (Form.set_min(schema, id, text), answers)
		5 => (Form.set_max(schema, id, text), answers)
		6 => (Form.set_required(schema, id, b % 2 == 0), answers)
		_ => (schema, Form.set_answer_text(answers, id, text))
	}
}

## The same step on the model's order of field ids.
model_step : List(Str), Form.Schema, U8, U8 -> List(Str)
model_step = |ids, before, op, a| {
	id = (before.fields.get(a.to_u64() % (before.fields.len() + 1)) ?? Form.prev_placeholder).id
	at = ids.find_first_index(|x| x == id)
	match (op % 8, at) {
		(0, _) => ids.append("f${(before.seq + 1).to_str()}")
		(1, _) => ids.drop_if(|x| x == id)
		(2, Ok(i)) if i > 0 => ids.swap(i - 1, i) ?? ids
		(3, Ok(i)) if i + 1 < ids.len() => ids.swap(i, i + 1) ?? ids
		_ => ids
	}
}

## Every property after every step, or the first that fails.
check : Input -> Try({}, Str)
check = |bytes| {
	var $state = ({ seq: 0, fields: [] }, [])
	var $ids = []
	var $i = 0
	while $i + 2 < bytes.len() {
		op = bytes.get($i) ?? 0
		a = bytes.get($i + 1) ?? 0
		b = bytes.get($i + 2) ?? 0
		$ids = model_step($ids, $state.0, op, a)
		$state = step($state, op, a, b)
		(schema, answers) = $state
		if schema.fields.map(|f| f.id) != $ids {
			return Err("after step ${($i // 3).to_str()} (op ${(op % 8).to_str()}) the fields are ${Str.inspect(schema.fields.map(|f| f.id))}, the model's ${Str.inspect($ids)}")
		}
		rows = Form.rows_of(schema.fields, answers)
		for (field, row) in List.map2(schema.fields, rows, |f, r| (f, r)) {
			bound = |t| match (Form.bound_of(t), model_bound(t)) {
				(NoBound, None) | (BadBound, Unsound) => Bool.True
				(HasBound(x), Whole(y)) => x.to_i128() == y
				_ => Bool.False
			}
			if !bound(field.min_text) or !bound(field.max_text) {
				return Err("the bounds ${Str.inspect(field.min_text)} and ${Str.inspect(field.max_text)} read as ${Str.inspect(Form.bound_of(field.min_text))} and ${Str.inspect(Form.bound_of(field.max_text))}")
			}
			match accepts(field, row.text) {
				Unsound if row.rule_error.is_empty() => return Err("${field.id}'s rule ${Str.inspect(field.min_text)} to ${Str.inspect(field.max_text)} is unsound, but the row has no rule error")
				Sound(_) if !row.rule_error.is_empty() => return Err("${field.id}'s rule ${Str.inspect(field.min_text)} to ${Str.inspect(field.max_text)} is sound, but the row says ${Str.inspect(row.rule_error)}")
				Sound(ok) if ok != row.error.is_empty() => return Err("${field.id} (${Form.kind_title(field.kind)}, required ${Str.inspect(field.required)}, ${Str.inspect(field.min_text)} to ${Str.inspect(field.max_text)}) says ${Str.inspect(row.error)} to ${Str.inspect(row.text)}")
				_ => {}
			}
		}
		if Form.problem_count(rows) != rows.count_if(|r| !r.error.is_empty()) {
			return Err("${Form.problem_count(rows).to_str()} problems counted among ${Str.inspect(rows.map(|r| r.error))}")
		}
		$i = $i + 3
	}
	Ok({})
}

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash problem
}

ex : Str, Input -> Fuzz.Example(Input)
ex = |name, input| Fuzz.example({ name, revision: "1", make: || input })

target = Fuzz.target_with!({
	name: "form-builder",
	examples: [
		# Two number fields; bounds 0 to 7 on the first; answers 12, 5, -0.
		ex("number-bounds", [0, 0, 0, 0, 0, 0, 4, 0, 1, 5, 0, 2, 7, 0, 4, 7, 0, 11, 7, 0, 12, 3, 0, 0, 2, 1, 0]),
		# A text field with a bound too large to read, then a sign.
		ex("unsound-bounds", [0, 0, 1, 5, 0, 7, 4, 0, 5, 7, 0, 10, 4, 0, 9]),
		ex("empty", []),
	],
	generator: Fuzz.list(Fuzz.u8, 240),
	test!,
	show: Str.inspect,
})
