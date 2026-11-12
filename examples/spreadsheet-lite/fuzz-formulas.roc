app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
}

import fz.Fuzz
import Cells
import Sheet

## The sheet's formulas, against a model that evaluates each formula's tree
## directly. The sheet reads a formula as text, tokenizes it, orders its
## operators and resolves its references in dependency order, finding
## reference cycles on the way, so the bugs to fear are in precedence, in
## what a reference or a range reads, and in cycles met from any cell.
##
## Each input decodes into a sheet of a few cells: empty, a whole number,
## text, or a formula of numbers, references, ranges (`SUM(B2:C3)`),
## negation, `+`, `-` and `*`, written out with the parentheses its tree
## needs. Its properties, for every cell of the sheet:
##
## - a cell whose formula reads, directly or through other formulas, a cell
##   on a reference cycle is an error, and so is one that reads text by
##   reference, reads an error, or multiplies past the sheet's range;
## - any other formula's number is its tree's, where an empty cell reads
##   as 0 and a range adds its numbers and skips its text;
## - every other cell is what it holds;
## - every cell's name reads back as its index;
## - the sheet's rows, which the app keeps in a table and writes row by
##   row, hold every cell at its index with what was typed into it and what
##   the sheet shows for it, and read back, in any order, as the text that
##   was typed.
Input : List(U8)

## A formula's tree.
Expr := [Num(I64), Ref(U64), Sum(U64, U64), Neg(Expr), Add(Expr, Expr), Sub(Expr, Expr), Mul(Expr, Expr)]

## What a cell holds.
Held : [Blank, Whole(I64), Words, Formula(Expr)]

## A cell's value in the model: what the sheet shows, without an error's
## text.
Value : [Empty, Number(I128), Text, Error]

## Bytes read one at a time; past the end they read as 0.
Bytes : { bytes : List(U8), at : U64 }

next : Bytes -> (U64, Bytes)
next = |r| ((r.bytes.get(r.at) ?? 0).to_u64(), { ..r, at: r.at + 1 })

## The sheet's cells, by index, that the input names: at most twelve, and
## a later cell at the same index replaces an earlier one.
sheet : List(U8) -> List((U64, Held))
sheet = |bytes| {
	var $r = { bytes, at: 0 }
	(count, r0) = next($r)
	$r = r0
	var $cells = []
	var $k = 0
	while $k < count % 12 + 1 {
		(index, r1) = next($r)
		(kind, r2) = next(r1)
		(held, r3) = match kind % 6 {
			0 => (Blank, r2)
			1 => {
				(n, r) = next(r2)
				(Whole(n.to_i64_wrap() - 50), r)
			}
			2 => (Words, r2)
			_ => {
				(e, r) = expr(r2, 3)
				(Formula(e), r)
			}
		}
		$cells = $cells.drop_if(|(i, _)| i == index % 24).append((index % 24, held))
		$r = r3
		$k = $k + 1
	}
	$cells
}

## A tree at most `depth` deep, over the sheet's first 24 cells (rows 1 to
## 3), so references meet often.
expr : Bytes, U64 -> (Expr, Bytes)
expr = |r0, depth| {
	(pick, r1) = next(r0)
	choice = if (depth == 0) pick % 3 else pick % 7
	match choice {
		0 => {
			(n, r) = next(r1)
			(Num(n.to_i64_wrap() % 40), r)
		}
		1 => {
			(i, r) = next(r1)
			(Ref(i % 24), r)
		}
		2 => {
			(a, r2) = next(r1)
			(b, r) = next(r2)
			(Sum(a % 24, b % 24), r)
		}
		3 => {
			(e, r) = expr(r1, depth - 1)
			(Neg(e), r)
		}
		_ => {
			(left, r2) = expr(r1, depth - 1)
			(right, r) = expr(r2, depth - 1)
			match choice {
				4 => (Add(left, right), r)
				5 => (Sub(left, right), r)
				_ => (Mul(left, right), r)
			}
		}
	}
}

## Whether a tree is an operator, so it needs parentheses on the right.
is_operator : Expr -> Bool
is_operator = |e| match e {
	Add(_, _) | Sub(_, _) | Mul(_, _) => Bool.True
	_ => Bool.False
}

## A tree as formula text, with the parentheses its shape needs:
## around a sum or a difference that is a product's left operand, around
## a sum or a difference that is a right operand and a product that is a
## product's right operand, and around a negation. A product to the right
## of `+` or `-` goes bare: precedence alone must give the tree.
text_of : Expr -> Str
text_of = |e| {
	right = |x| if (is_operator(x)) "(${text_of(x)})" else text_of(x)
	term = |x|
		match x {
			Mul(_, _) => text_of(x)
			_ => right(x)
		}
	match e {
		Num(n) => n.to_str()
		Ref(i) => Cells.ref_of(i)
		Sum(a, b) => "SUM(${Cells.ref_of(a)}:${Cells.ref_of(b)})"
		Neg(x) => "(-${right(x)})"
		Add(a, b) => "${text_of(a)}+${term(b)}"
		Sub(a, b) => "${text_of(a)}-${term(b)}"
		Mul(a, b) => {
			left = match a {
				Add(_, _) | Sub(_, _) => "(${text_of(a)})"
				_ => text_of(a)
			}
			"${left}*${right(b)}"
		}
	}
}

## The cells a tree reads.
reads : Expr -> List(U64)
reads = |e| match e {
	Num(_) => []
	Ref(i) => [i]
	Sum(a, b) => Cells.expand_range(a, b)
	Neg(x) => reads(x)
	Add(a, b) | Sub(a, b) | Mul(a, b) => reads(a).concat(reads(b))
}

held_at : List((U64, Held)), U64 -> Held
held_at = |cells, index| match cells.find_first(|(i, _)| i == index) {
	Ok((_, held)) => held
	Err(_) => Blank
}

## Whether a formula at `index` reaches a reference cycle: a path of
## references from it comes back to a cell already on the path.
reaches_cycle : List((U64, Held)), U64, List(U64) -> Bool
reaches_cycle = |cells, index, path|
	if path.contains(index) {
		Bool.True
	} else {
		match held_at(cells, index) {
			Formula(e) => reads(e).any(|j| reaches_cycle(cells, j, path.append(index)))
			_ => Bool.False
		}
	}

## The largest whole number a product may have: the sheet's bound.
max_product : I128
max_product = 100_000_000_000_000

## A tree's number in the model, or an error.
eval : List((U64, Held)), Expr -> Try(I128, [Error])
eval = |cells, e| match e {
	Num(n) => Ok(n.to_i128())
	Ref(i) =>
		match value(cells, i) {
			Empty => Ok(0)
			Number(n) => Ok(n)
			Text | Error => Err(Error)
		}
	Sum(a, b) => {
		var $total = 0.I128
		for i in Cells.expand_range(a, b) {
			match value(cells, i) {
				Number(n) => {
					$total = $total + n
				}
				Error => return Err(Error)
				Empty | Text => {}
			}
		}
		Ok($total)
	}
	Neg(x) => Ok(0 - eval(cells, x)?)
	Add(a, b) => {
		x = eval(cells, a)
		y = eval(cells, b)
		Ok(x? + y?)
	}
	Sub(a, b) => {
		x = eval(cells, a)
		y = eval(cells, b)
		Ok(x? - y?)
	}
	Mul(a, b) => {
		x = eval(cells, a)?
		y = eval(cells, b)?
		if x.abs() > 100_000_000 or y.abs() > 100_000_000 or (x * y).abs() > max_product {
			Err(Error)
		} else {
			Ok(x * y)
		}
	}
}

## A cell's value in the model.
value : List((U64, Held)), U64 -> Value
value = |cells, index| match held_at(cells, index) {
	Blank => Empty
	Whole(n) => Number(n.to_i128())
	Words => Text
	Formula(e) =>
		if reaches_cycle(cells, index, []) {
			Error
		} else {
			match eval(cells, e) {
				Ok(n) => Number(n)
				Err(Error) => Error
			}
		}
}

## The text the sheet is given for a cell.
source_of : Held -> Str
source_of = |held| match held {
	Blank => ""
	Whole(n) => n.to_str()
	Words => "note"
	Formula(e) => "=${text_of(e)}"
}

## Every property, or the first that fails.
check : Input -> Try({}, Str)
check = |bytes| {
	cells = sheet(bytes)
	sources = List.repeat("", Cells.cell_count).map_with_index(|_, i| source_of(held_at(cells, i)))
	shown = Sheet.evaluate(sources)
	scale = Cells.scale.to_i128()
	for (index, held) in cells {
		got = shown.get(index) ?? Empty
		want = value(cells, index)
		agrees = match (got, want) {
			(Empty, Empty) => Bool.True
			(Number(n), Number(m)) => n.to_i128() == m * scale
			(Text(_), Text) => Bool.True
			(Bad(_), Error) => Bool.True
			_ => Bool.False
		}
		if !agrees {
			return Err("${Cells.ref_of(index)} = ${Str.inspect(source_of(held))} shows ${Str.inspect(got)}, the model ${Str.inspect(want)}; the sheet: ${Str.inspect(cells.map(|(i, h)| "${Cells.ref_of(i)}: ${source_of(h)}"))}")
		}
	}
	rows = Sheet.rows_of(sources)
	in_rows = rows.map(|entry| entry.row).join()
	for index in List.repeat(0, Cells.cell_count).map_with_index(|_, i| i) {
		if Cells.index_of(Cells.ref_of(index)) != Ok(index) {
			return Err("${Cells.ref_of(index)} does not read back as cell ${index.to_str()}")
		}
		on_sheet = { index, source: sources.get(index) ?? "", out: Sheet.to_out(shown.get(index) ?? Empty) }
		if in_rows.get(index) != Ok(on_sheet) {
			return Err("the rows hold ${Str.inspect(in_rows.get(index))} at ${Cells.ref_of(index)}, the sheet ${Str.inspect(on_sheet)}")
		}
	}
	numbers = rows.map(|entry| entry.key)
	if numbers != List.repeat(0, Cells.row_count).map_with_index(|_, i| i) or rows.any(|entry| entry.row.len() != Cells.col_count) {
		return Err("the rows are numbered ${Str.inspect(numbers)} and hold ${Str.inspect(rows.map(|entry| entry.row.len()))} cells")
	}
	if rows.rev().fold(Sheet.blank_sources, |typed, entry| Sheet.with_row(typed, entry.row)) != sources {
		return Err("the rows do not read back as what was typed; the sheet: ${Str.inspect(cells.map(|(i, h)| "${Cells.ref_of(i)}: ${source_of(h)}"))}")
	}
	Ok({})
}

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash problem
}

ex : Str, List(U8) -> Fuzz.Example(Input)
ex = |name, cells| Fuzz.example({ name, revision: "1", make: || cells })

target = Fuzz.target_with!({
	name: "spreadsheet-lite",
	examples: [
		# A1 = 2+3*4, which is 14 only if `*` binds tighter than `+`.
		ex("precedence", [0, 0, 3, 4, 0, 2, 6, 0, 3, 0, 4]),
		# A1 = 7, B1 = A1*(A1+2) with B1's sum as a right operand.
		ex("references", [1, 0, 1, 57, 1, 6, 6, 1, 0, 4, 1, 0, 0, 2]),
		# A1 = B1, B1 = A1: a cycle, and C1 reading it.
		ex("cycle", [2, 0, 3, 1, 1, 1, 3, 1, 0, 2, 3, 1, 0]),
		ex("empty", []),
	],
	generator: Fuzz.list(Fuzz.u8, 200),
	test!,
	show: Str.inspect,
})
