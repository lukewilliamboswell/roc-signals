## Formula tokenizing and evaluation.
##
## `tokenize` turns a formula body into tokens, `refs_of` reads the dependency
## edges straight out of those tokens, and `eval_tokens` evaluates them against
## dependency slots that the sheet has already resolved.
import Cells

Formula := [].{

	## A computed cell value.
	Value : [Empty, Number(I64), Text(Str), Bad(Str)]

	## Evaluation slot used while walking the dependency graph.
	Slot : [Pending, Busy, Ready(Value)]

	## A formula token. `TSum` carries the already-expanded member indices of a

	## rectangular range.
	Tok : [TNum(I64), TRef(U64), TSum(List(U64)), TOp(U8), TOpen, TClose, TBad]

	starts_with_sum : List(U8) -> Bool
	starts_with_sum = |bytes|
		Cells.byte_at(bytes, 0)
		== 'S'
		and Cells.byte_at(bytes, 1) == 'U'
		and Cells.byte_at(bytes, 2) == 'M'
		and Cells.byte_at(bytes, 3) == '('

	## Parse `SUM(A1:B3)` into a token holding the range members.
	parse_sum : List(U8) -> Try({ token : Tok, rest : List(U8) }, [NotASum])
	parse_sum = |bytes| {
		from = Cells.parse_ref(bytes.drop_first(4)) ? |_| NotASum
		if Cells.byte_at(from.rest, 0) != ':' {
			Err(NotASum)
		} else {
			to = Cells.parse_ref(from.rest.drop_first(1)) ? |_| NotASum
			if Cells.byte_at(to.rest, 0) != ')' {
				Err(NotASum)
			} else {
				Ok(
					{
						token: TSum(Cells.expand_range(from.index, to.index)),
						rest: to.rest.drop_first(1),
					},
				)
			}
		}
	}

	## Tokenize a formula body (the text after the leading `=`).
	tokenize : Str -> List(Tok)
	tokenize = |body| {
		var $rest = body.to_utf8()
		var $out = []
		# True while the next `-` would be a unary minus: at the start of the
		# formula and directly after an operator or an open paren.
		var $unary_position = True

		while !$rest.is_empty() {
			byte = Cells.byte_at($rest, 0)
			if byte == ' ' {
				$rest = $rest.drop_first(1)
			} else if Cells.is_digit(byte) or byte == '.' {
				match Cells.take_number($rest) {
					Ok(parsed) => {
						$out = $out.append(TNum(parsed.value))
						$rest = parsed.rest
						$unary_position = False
					}
					Err(_) => {
						$out = $out.append(TBad)
						$rest = $rest.drop_first(1)
					}
				}
			} else if Formula.starts_with_sum($rest) {
				match Formula.parse_sum($rest) {
					Ok(parsed) => {
						$out = $out.append(parsed.token)
						$rest = parsed.rest
						$unary_position = False
					}
					Err(_) => {
						$out = $out.append(TBad)
						$rest = $rest.drop_first(1)
					}
				}
			} else if byte >= 'A' and byte <= 'Z' {
				match Cells.parse_ref($rest) {
					Ok(parsed) => {
						$out = $out.append(TRef(parsed.index))
						$rest = parsed.rest
						$unary_position = False
					}
					Err(_) => {
						$out = $out.append(TBad)
						$rest = $rest.drop_first(1)
					}
				}
			} else if byte == '-' {
				if $unary_position {
					$out = $out.append(TNum(0))
				}
				$out = $out.append(TOp('-'))
				$rest = $rest.drop_first(1)
				$unary_position = True
			} else if byte == '+' or byte == '*' or byte == '/' {
				$out = $out.append(TOp(byte))
				$rest = $rest.drop_first(1)
				$unary_position = True
			} else if byte == '(' {
				$out = $out.append(TOpen)
				$rest = $rest.drop_first(1)
				$unary_position = True
			} else if byte == ')' {
				$out = $out.append(TClose)
				$rest = $rest.drop_first(1)
				$unary_position = False
			} else {
				$out = $out.append(TBad)
				$rest = $rest.drop_first(1)
			}
		}

		$out
	}

	## Every cell index a token list reads, in order. These are the dependency

	## edges the evaluator walks before computing a cell.
	refs_of : List(Tok) -> List(U64)
	refs_of = |tokens| {
		var $out = []
		var $index = 0

		while $index < tokens.len() {
			match tokens.get($index) {
				Ok(TRef(cell)) => {
					$out = $out.append(cell)
				}
				Ok(TSum(cells)) => {
					$out = $out.concat(cells)
				}
				_ => {}
			}

			$index = $index + 1
		}

		$out
	}

	precedence : U8 -> U64
	precedence = |op| if op == '*' or op == '/' { 2 } else { 1 }

	## Shunting-yard: infix tokens to reverse polish order.
	to_rpn : List(Tok) -> Try(List(Tok), [BadFormula])
	to_rpn = |tokens| {
		var $out = []
		var $ops = []
		var $bad = False
		var $index = 0

		while $index < tokens.len() {
			token = tokens.get($index) ?? TBad

			match token {
				TBad => {
					$bad = True
				}
				TNum(_) => {
					$out = $out.append(token)
				}
				TRef(_) => {
					$out = $out.append(token)
				}
				TSum(_) => {
					$out = $out.append(token)
				}
				TOpen => {
					$ops = $ops.append('(')
				}
				TClose => {
					var $open = True

					while $open and !$ops.is_empty() {
						top = Cells.byte_at($ops, $ops.len() - 1)
						$ops = $ops.drop_last(1)
						if top == '(' {
							$open = False
						} else {
							$out = $out.append(TOp(top))
						}
					}

					if $open {
						$bad = True
					}
				}
				TOp(op) => {
					var $popping = True

					while $popping {
						if $ops.is_empty() {
							$popping = False
						} else {
							top = Cells.byte_at($ops, $ops.len() - 1)
							if top == '(' or Formula.precedence(top) < Formula.precedence(op) {
								$popping = False
							} else {
								$ops = $ops.drop_last(1)
								$out = $out.append(TOp(top))
							}
						}
					}

					$ops = $ops.append(op)
				}
			}

			$index = $index + 1
		}

		while !$ops.is_empty() {
			top = Cells.byte_at($ops, $ops.len() - 1)
			$ops = $ops.drop_last(1)
			if top == '(' {
				$bad = True
			} else {
				$out = $out.append(TOp(top))
			}
		}

		if $bad {
			Err(BadFormula)
		} else {
			Ok($out)
		}
	}

	slot_value : List(Slot), U64 -> Value
	slot_value = |slots, index|
		match slots.get(index) {
			Ok(Ready(value)) => value
			_ => Empty
		}

	## Evaluate a token list against already-resolved dependency slots.
	eval_tokens : List(Tok), List(Slot) -> Value
	eval_tokens = |tokens, slots|
		match Formula.to_rpn(tokens) {
			Err(_) => Bad("#ERROR!")
			Ok(rpn) => {
				var $stack = []
				# The first failure wins: once this is `Failed`, the remaining tokens
				# are skipped and its message becomes the cell's displayed text.
				var $error = NoError
				var $index = 0

				while $index < rpn.len() {
					token = rpn.get($index) ?? TBad

					match $error {
						NoError => match token {
							TBad => {
								$error = Failed("#ERROR!")
							}
							TOpen => {
								$error = Failed("#ERROR!")
							}
							TClose => {
								$error = Failed("#ERROR!")
							}
							TNum(value) => {
								$stack = $stack.append(value)
							}
							TRef(cell) => {
								match Formula.slot_value(slots, cell) {
									Empty => {
										$stack = $stack.append(0)
									}
									Number(value) => {
										$stack = $stack.append(value)
									}
									Text(_) => {
										$error = Failed("#VALUE!")
									}
									Bad(message) => {
										$error = Failed(message)
									}
								}
							}
							TSum(cells) => {
								var $total = 0
								var $member = 0

								while $member < cells.len() {
									cell = cells.get($member) ?? 0

									match Formula.slot_value(slots, cell) {
										Empty => {}
										Number(value) => {
											$total = $total + value
										}
										Text(_) => {}
										Bad(message) => {
											$error = Failed(message)
										}
									}

									$member = $member + 1
								}

								$stack = $stack.append($total)
							}
							TOp(op) => {
								if $stack.len() < 2 {
									$error = Failed("#ERROR!")
								} else {
									right = $stack.get($stack.len() - 1) ?? 0
									left = $stack.get($stack.len() - 2) ?? 0
									$stack = $stack.drop_last(2)
									if op == '+' {
										$stack = $stack.append(left + right)
									} else if op == '-' {
										$stack = $stack.append(left - right)
									} else if op == '*' {
										match Cells.multiply(left, right) {
											Ok(value) => {
												$stack = $stack.append(value)
											}
											Err(_) => {
												$error = Failed("#NUM!")
											}
										}
									} else {
										match Cells.divide(left, right) {
											Ok(value) => {
												$stack = $stack.append(value)
											}
											Err(DivideByZero) => {
												$error = Failed("#DIV/0!")
											}
											Err(_) => {
												$error = Failed("#NUM!")
											}
										}
									}
								}
							}
						}
						Failed(_) => {}
					}

					$index = $index + 1
				}

				match $error {
					Failed(message) => Bad(message)
					NoError =>
						match $stack.first() {
							Ok(value) if $stack.len() == 1 => Number(value)
							_ => Bad("#ERROR!")
						}
				}
			}
		}

	## A non-formula cell is empty, a number, or text.
	literal_value : Str -> Value
	literal_value = |source|
		if source.is_empty() {
			Empty
		} else {
			negative = source.starts_with("-")
			digits = if negative { source.drop_prefix("-") } else { source }
			match Cells.take_number(digits.to_utf8()) {
				Ok(parsed) if parsed.rest.is_empty() =>
					if negative {
						Number(0 - parsed.value)
					} else {
						Number(parsed.value)
					}
				_ => Text(source)
			}
		}

	## The cell references a formula reads, as text such as "B2, C2".
	depends_on : Str -> Str
	depends_on = |source| {
		trimmed = source.trim()
		if !trimmed.starts_with("=") {
			"none"
		} else {
			refs = Formula.refs_of(Formula.tokenize(trimmed.drop_prefix("=")))
			if refs.is_empty() {
				"none"
			} else {
				Str.join_with(refs.map(Cells.ref_of), ", ")
			}
		}
	}
}

## A literal cell reads no other cells.
expect Formula.depends_on("1200") == "none"

## A formula built only from numbers has no dependency edges.
expect Formula.depends_on("=2+3*4") == "none"

## Each reference in a formula becomes a dependency edge, in the order read.
expect Formula.depends_on("=B2+C2") == "B2, C2"

## A SUM range contributes every member of the range as its own edge.
expect Formula.depends_on("=SUM(B2:B4)") == "B2, B3, B4"

## An empty source is an empty cell, not empty text.
expect Formula.literal_value("") == Empty

## A bare integer literal becomes a fixed-point number.
expect Formula.literal_value("1200") == Number(1200 * Cells.scale)

## A leading minus is part of the literal, not an operator.
expect Formula.literal_value("-2.5") == Number(0 - 25000)

## Anything that is not a number stays text.
expect Formula.literal_value("oops") == Text("oops")

## A number with trailing junk is text, not a partially parsed number.
expect Formula.literal_value("12x3") == Text("12x3")

## Multiplication and division bind tighter than addition and subtraction.
expect Formula.eval_tokens(Formula.tokenize("2+3*4-6/3"), []) == Number(12 * Cells.scale)

## A minus at the start of a formula is unary, not a missing left operand.
expect Formula.eval_tokens(Formula.tokenize("-3+10"), []) == Number(7 * Cells.scale)

## Parentheses override precedence.
expect Formula.eval_tokens(Formula.tokenize("(1+2)*(3+4)"), []) == Number(21 * Cells.scale)

## Division truncates at four decimal places rather than rounding.
expect Formula.eval_tokens(Formula.tokenize("10/3"), []) == Number(33333)

## A zero divisor surfaces as the spreadsheet's divide-by-zero text.
expect Formula.eval_tokens(Formula.tokenize("1/0"), []) == Bad("#DIV/0!")

## An operator with no right operand is a formula error.
expect Formula.eval_tokens(Formula.tokenize("1+"), []) == Bad("#ERROR!")

## An unclosed parenthesis is a formula error.
expect Formula.eval_tokens(Formula.tokenize("(1+2"), []) == Bad("#ERROR!")

## A reference outside the sheet tokenizes as bad input and fails the formula.
expect Formula.eval_tokens(Formula.tokenize("Z9+1"), []) == Bad("#ERROR!")
