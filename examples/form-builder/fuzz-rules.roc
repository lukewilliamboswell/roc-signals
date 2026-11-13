app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
}

import fz.Fuzz
import Form

## The form builder's schema edits and its validation, against a model.
## The form holds its fields by number, each with its place in the form's
## order, and a move exchanges the places of two fields, and the preview
## parses each rule's bounds from the text the designer typed, so the bugs
## to fear are a field lost, doubled or moved too far, two fields left at
## one place, and an answer judged against a bound that was read wrongly.
##
## Each input decodes into a sequence of designer steps (add a field of any
## kind, delete one, move one up or down, type its minimum or maximum,
## toggle it required, type an answer) from pieces that include signs,
## spaces, `+`, `_` and numbers too large for a bound. After every step:
##
## - the fields, in the order their views draw them, are the model's, and
##   no two stand at one place;
## - a bound is no bound when blank, a whole number when it is one (an
##   optional `-` and decimal digits that fit), and otherwise a rule error;
## - a number or text field whose rule is sound accepts exactly a blank
##   answer when it is not required, or a whole number (a length, for
##   text) within its bounds;
## - the totals count every field, and as problems the rows with an error.
Input : List(U8)

## What the designer and the preview hold between steps: the fields, the
## number the next field takes, and the answers.
Held : { fields : Form.Fields, next : U64, answers : Form.Answers }

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

## The number of the field a byte picks from the model's order, or 0, which
## no field has, when it picks none.
picked : List(U64), U8 -> U64
picked = |ids, a| ids.get(a.to_u64() % (ids.len() + 1)) ?? 0

## The fields with the field numbered `key` changed by `change`, as the
## designer's row writes it; a number the form does not hold changes
## nothing.
with_field : Form.Fields, U64, (Form.Field -> Form.Field) -> Form.Fields
with_field = |fields, key, change|
	match fields.find_first(|held| held.key == key) {
		Ok(held) => Form.edited(fields, [Put(key, change(held.row))])
		Err(_) => fields
	}

## One step of the designer, from three bytes.
step : Held, List(U64), U8, U8, U8 -> Held
step = |{ fields, next, answers }, ids, op, a, b| {
	key = picked(ids, a)
	text = pieces.get(b.to_u64() % pieces.len()) ?? ""
	match op % 8 {
		0 => { fields: Form.edited(fields, [Put(next, Form.new_field(if (b % 2 == 0) Form.number_kind else Form.text_kind, next))]), next: next + 1, answers }
		1 => { fields: Form.edited(fields, [Remove(key)]), next, answers }
		2 => { fields: Form.edited(fields, Form.move_field(fields, { key, toward: Earlier })), next, answers }
		3 => { fields: Form.edited(fields, Form.move_field(fields, { key, toward: Later })), next, answers }
		4 => { fields: with_field(fields, key, |field| Form.set_min(field, text)), next, answers }
		5 => { fields: with_field(fields, key, |field| Form.set_max(field, text)), next, answers }
		6 => { fields: with_field(fields, key, |field| Form.set_required(field, b % 2 == 0)), next, answers }
		_ => { fields, next, answers: Form.set_answer_text(answers, key, text) }
	}
}

## The same step on the model's order of field numbers.
model_step : List(U64), U64, U8, U8 -> List(U64)
model_step = |ids, next, op, a| {
	key = picked(ids, a)
	at = ids.find_first_index(|x| x == key)
	match (op % 8, at) {
		(0, _) => ids.append(next)
		(1, _) => ids.drop_if(|x| x == key)
		(2, Ok(i)) if i > 0 => ids.swap(i - 1, i) ?? ids
		(3, Ok(i)) if i + 1 < ids.len() => ids.swap(i, i + 1) ?? ids
		_ => ids
	}
}

## Every property after every step, or the first that fails.
check : Input -> Try({}, Str)
check = |bytes| {
	var $held = { fields: [], next: 1, answers: Form.no_answers }
	var $ids = []
	var $i = 0
	while $i + 2 < bytes.len() {
		op = bytes.get($i) ?? 0
		a = bytes.get($i + 1) ?? 0
		b = bytes.get($i + 2) ?? 0
		before = $ids
		$ids = model_step(before, $held.next, op, a)
		$held = step($held, before, op, a, b)
		{ fields, answers, .. } = $held
		if Form.ordered(fields) != $ids {
			return Err("after step ${($i // 3).to_str()} (op ${(op % 8).to_str()}) the fields are ${Str.inspect(Form.ordered(fields))}, the model's ${Str.inspect($ids)}")
		}
		places = fields.map(|held| held.row.place)
		if Set.from_list(places).len() != places.len() {
			return Err("two fields stand at one place: ${Str.inspect(fields.map(|held| (held.key, held.row.place)))}")
		}
		rows = fields.map(|held| Form.row_of(held.row, Form.answer_of(answers, held.key)))
		for (held, row) in List.map2(fields, rows, |f, r| (f, r)) {
			field = held.row
			bound = |t| match (Form.bound_of(t), model_bound(t)) {
				(NoBound, None) | (BadBound, Unsound) => Bool.True
				(HasBound(x), Whole(y)) => x.to_i128() == y
				_ => Bool.False
			}
			if !bound(field.min_text) or !bound(field.max_text) {
				return Err("the bounds ${Str.inspect(field.min_text)} and ${Str.inspect(field.max_text)} read as ${Str.inspect(Form.bound_of(field.min_text))} and ${Str.inspect(Form.bound_of(field.max_text))}")
			}
			name = Form.id_of(held.key)
			match accepts(field, row.text) {
				Unsound if row.rule_error.is_empty() => return Err("${name}'s rule ${Str.inspect(field.min_text)} to ${Str.inspect(field.max_text)} is unsound, but the row has no rule error")
				Sound(_) if !row.rule_error.is_empty() => return Err("${name}'s rule ${Str.inspect(field.min_text)} to ${Str.inspect(field.max_text)} is sound, but the row says ${Str.inspect(row.rule_error)}")
				Sound(ok) if ok != row.error.is_empty() => return Err("${name} (${Form.kind_title(field.kind)}, required ${Str.inspect(field.required)}, ${Str.inspect(field.min_text)} to ${Str.inspect(field.max_text)}) says ${Str.inspect(row.error)} to ${Str.inspect(row.text)}")
				_ => {}
			}
		}
		totals = rows.fold(Form.empty_totals, Form.counted)
		if totals != { fields: rows.len(), problems: rows.count_if(|r| !r.error.is_empty()) } {
			return Err("the totals are ${Str.inspect(totals)} over ${Str.inspect(rows.map(|r| r.error))}")
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
