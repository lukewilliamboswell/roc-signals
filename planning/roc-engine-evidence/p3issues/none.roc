app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Node := [Node((U64 -> (Node, U64)))]

# The closure captures a refcounted List. Its body is deliberately large and
# contains the marker constant 987654321 so copies are easy to count.
mk : List(U64) -> Node
mk = |data| Node(|x| {
	var $a = x
	for d in data {
		$a = ($a * 7 + d + 987654321) % 1000003
		$a = if $a % 3 == 0 { $a // 3 } else { $a + 3 }
		$a = ($a * 11 + d + 987654321) % 1000033
		$a = if $a % 5 == 0 { $a // 5 } else { $a + 5 }
		$a = ($a * 13 + d + 987654321) % 1000037
		$a = if $a % 7 == 0 { $a // 7 } else { $a + 7 }
		$a = ($a * 17 + d + 987654321) % 1000039
		$a = if $a % 11 == 0 { $a // 11 } else { $a + 11 }
		$a = ($a * 19 + d + 987654321) % 1000081
		$a = if $a % 13 == 0 { $a // 13 } else { $a + 13 }
		$a = ($a * 23 + d + 987654321) % 1000099
		$a = if $a % 17 == 0 { $a // 17 } else { $a + 17 }
		$a = ($a * 29 + d + 987654321) % 1000117
		$a = if $a % 19 == 0 { $a // 19 } else { $a + 19 }
		$a = ($a * 31 + d + 987654321) % 1000121
		$a = if $a % 23 == 0 { $a // 23 } else { $a + 23 }
		$a = ($a * 37 + d + 987654321) % 1000133
		$a = if $a % 29 == 0 { $a // 29 } else { $a + 29 }
		$a = ($a * 41 + d + 987654321) % 1000151
		$a = if $a % 31 == 0 { $a // 31 } else { $a + 31 }
	}
	(mk(data.append($a)), $a)
})

call : Node, U64 -> (Node, U64)
call = |Node(f), x| f(x)

# Owned call: take each node out of the list, call it, put the result back.
step_all : List(Node), U64 -> (List(Node), U64)
step_all = |nodes, x| {
	var $ns = nodes
	var $sum = 0
	var $i = 0
	while $i < $ns.len() {
		match $ns.replace($i, mk([])) {
			Ok({ list, prev }) => {
				(next, v) = call(prev, x)
				$ns = list.set($i, next) ?? crash "set"
				$sum = $sum + v
			}
			Err(_) => crash "replace"
		}
		$i = $i + 1
	}
	($ns, $sum)
}

peek_all : List(Node), U64 -> U64
peek_all = |_nodes, _x| 0

run! : Str => Str
run! = |input| {
	x = input.count_utf8_bytes().to_u64()
	(ns, a) = step_all([mk([1]), mk([2]), mk([3])], x)
	b = peek_all(ns, x)
	(a + b).to_str()
}
