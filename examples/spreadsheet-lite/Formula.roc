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
	parse_sum = |bytes|
		match Cells.parse_ref(bytes.drop_first(4)) {
			Ok(from) =>
				if Cells.byte_at(from.rest, 0) != ':' {
					Err(NotASum)
				} else {
					match Cells.parse_ref(from.rest.drop_first(1)) {
						Ok(to) =>
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
						Err(_) => Err(NotASum)
					}
				}
			Err(_) => Err(NotASum)
		}

	## Tokenize a formula body (the text after the leading `=`).
	tokenize : Str -> List(Tok)
	tokenize = |body| {
		var $rest = body.to_utf8()
		var $out = []
		var $after_value = Cells.no

		while !$rest.is_empty() {
			byte = Cells.byte_at($rest, 0)
			if byte == ' ' {
				$rest = $rest.drop_first(1)
			} else if Cells.is_digit(byte) or byte == '.' {
				match Cells.take_number($rest) {
					Ok(parsed) => {
						$out = $out.append(TNum(parsed.value))
						$rest = parsed.rest
						$after_value = Cells.yes
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
						$after_value = Cells.yes
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
						$after_value = Cells.yes
					}
					Err(_) => {
						$out = $out.append(TBad)
						$rest = $rest.drop_first(1)
					}
				}
			} else if byte == '-' {
				if !$after_value {
					$out = $out.append(TNum(0))
				}
				$out = $out.append(TOp('-'))
				$rest = $rest.drop_first(1)
				$after_value = Cells.no
			} else if byte == '+' or byte == '*' or byte == '/' {
				$out = $out.append(TOp(byte))
				$rest = $rest.drop_first(1)
				$after_value = Cells.no
			} else if byte == '(' {
				$out = $out.append(TOpen)
				$rest = $rest.drop_first(1)
				$after_value = Cells.no
			} else if byte == ')' {
				$out = $out.append(TClose)
				$rest = $rest.drop_first(1)
				$after_value = Cells.yes
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
		var $bad = Cells.no
		var $index = 0

		while $index < tokens.len() {
			token =
				match tokens.get($index) {
					Ok(value) => value
					Err(_) => TBad
				}

			match token {
				TBad => {
					$bad = Cells.yes
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
					var $closed = Cells.no

					while !$closed and !$ops.is_empty() {
						top = Cells.byte_at($ops, $ops.len() - 1)
						$ops = $ops.drop_last(1)
						if top == '(' {
							$closed = Cells.yes
						} else {
							$out = $out.append(TOp(top))
						}
					}

					if !$closed {
						$bad = Cells.yes
					}
				}
				TOp(op) => {
					var $popping = Cells.yes

					while $popping {
						if $ops.is_empty() {
							$popping = Cells.no
						} else {
							top = Cells.byte_at($ops, $ops.len() - 1)
							if top == '(' or Formula.precedence(top) < Formula.precedence(op) {
								$popping = Cells.no
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
				$bad = Cells.yes
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
				var $error = ""
				var $index = 0

				while $index < rpn.len() {
					token =
						match rpn.get($index) {
							Ok(value) => value
							Err(_) => TBad
						}

					if $error == "" {
						match token {
							TBad => {
								$error = "#ERROR!"
							}
							TOpen => {
								$error = "#ERROR!"
							}
							TClose => {
								$error = "#ERROR!"
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
										$error = "#VALUE!"
									}
									Bad(message) => {
										$error = message
									}
								}
							}
							TSum(cells) => {
								var $total = 0
								var $member = 0

								while $member < cells.len() {
									cell =
										match cells.get($member) {
											Ok(value) => value
											Err(_) => 0
										}

									match Formula.slot_value(slots, cell) {
										Empty => {}
										Number(value) => {
											$total = $total + value
										}
										Text(_) => {}
										Bad(message) => {
											$error = message
										}
									}

									$member = $member + 1
								}

								$stack = $stack.append($total)
							}
							TOp(op) => {
								if $stack.len() < 2 {
									$error = "#ERROR!"
								} else {
									right =
										match $stack.get($stack.len() - 1) {
											Ok(value) => value
											Err(_) => 0
										}
									left =
										match $stack.get($stack.len() - 2) {
											Ok(value) => value
											Err(_) => 0
										}
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
												$error = "#NUM!"
											}
										}
									} else {
										match Cells.divide(left, right) {
											Ok(value) => {
												$stack = $stack.append(value)
											}
											Err(DivideByZero) => {
												$error = "#DIV/0!"
											}
											Err(_) => {
												$error = "#NUM!"
											}
										}
									}
								}
							}
						}
					}

					$index = $index + 1
				}

				if $error != "" {
					Bad($error)
				} else if $stack.len() == 1 {
					match $stack.first() {
						Ok(value) => Number(value)
						Err(_) => Bad("#ERROR!")
					}
				} else {
					Bad("#ERROR!")
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
				Ok(parsed) =>
					if parsed.rest.is_empty() {
						if negative {
							Number(0 - parsed.value)
						} else {
							Number(parsed.value)
						}
					} else {
						Text(source)
					}
				Err(_) => Text(source)
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
