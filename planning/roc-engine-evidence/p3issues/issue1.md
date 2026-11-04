## Summary

A closure stored in a nominal tag is called from two places: once after taking it out of a list with `List.replace` (owned), and once while iterating the list with `for n in nodes` (borrowed). The compiler emits the whole closure body twice, once per call form. If the borrowed call site is rewritten to the owned `replace` pattern, the body is emitted once.

Compiler: `nightly-2026-11-03-34bd006`, Linux x86_64 (`x64musl`), `--opt=size` and `--opt=speed`. I used the `test/alloc-count` platform from this repository.

Real-world impact: in a reactive UI engine where each node is a self-rebuilding closure, one borrowed child-call loop on a rarely used dispose path doubled every closure body reachable from it. That was about 30% of a 460 KB Wasm app: 463.5 KB before and 326.8 KB after rewriting only the three borrowed child-call loops to the owned form (sizes after `wasm-opt -Oz`). Allocation counts were identical before and after.

## Reproduction

Put `borrowed.roc` next to `test/alloc-count/platform`:

```roc
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

# BORROWED: call each node while iterating the list.
peek_all : List(Node), U64 -> U64
peek_all = |nodes, x| {
	var $sum = 0
	for n in nodes {
		(_, v) = call(n, x)
		$sum = $sum + v
	}
	$sum
}

run! : Str => Str
run! = |input| {
	x = input.count_utf8_bytes().to_u64()
	(ns, a) = step_all([mk([1]), mk([2]), mk([3])], x)
	b = peek_all(ns, x)
	(a + b).to_str()
}
```

`owned.roc` is identical except `peek_all` reuses the owned loop:

```roc
peek_all : List(Node), U64 -> U64
peek_all = |nodes, x| {
	(_, sum) = step_all(nodes, x)
	sum
}
```

`none.roc` (a baseline) has `peek_all = |_nodes, _x| 0`.

```sh
ROC=~/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
for f in none owned borrowed; do
  $ROC build --opt=size --no-cache --output=$f.bin $f.roc
  echo "$f text=$(size $f.bin | tail -1 | cut -f1) copies=$(objdump -d $f.bin | grep -ci 3ade68b1)"
done
```

`0x3ADE68B1` is the marker constant `987654321`, which appears 10 times in the closure body.

## Measured

| file | `--opt=size` text | marker occurrences | `--opt=speed` text | marker occurrences |
|---|---|---|---|---|
| none.roc | 136252 | 10 (1 copy) | 136453 | 10 (1 copy) |
| owned.roc | 136984 | 10 (1 copy) | 137313 | 10 (1 copy) |
| borrowed.roc | 137628 | 20 (2 copies) | 137877 | 20 (2 copies) |

Compared with the baseline, the owned call site adds 732 bytes and the borrowed one adds 1376 bytes (size). In `borrowed.bin` the two copies sit about 0x6a0 bytes apart (markers at 0x2210d5..0x22146d and 0x221772..0x221b14). Both builds print the same result.

## Expected

One specialisation of the closure body, with the borrowed-versus-owned difference handled at the call site (for example by incrementing the captures or the callable before the call), or at most a borrowed variant for only the procedures the borrowed path actually reaches. Today the ownership mode of one call site duplicates the entire reachable body, so code size depends on an incidental choice between `for` and `List.replace`.
