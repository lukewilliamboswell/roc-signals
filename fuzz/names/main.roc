app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}
import fz.Fuzz
import pf.Web
import NameModel
import NameCorpus

Input : [Corpus(NameCorpus.Case), Generated(Str)]

## Grammar decisions must match an independent model. Fixed cases also pin
## that model to the input facts checked against real DOM and Fetch APIs.
check_names : Input -> {}
check_names = |input| {
	text = match input {
		Corpus(case) => case.text
		Generated(value) => value
	}
	reference = NameModel.accepts(text)
	match input {
		Corpus(case) if reference != case.expected => crash "name model differs from corpus ${case.name}: ${Str.inspect(reference)}, expected ${Str.inspect(case.expected)}"
		_ => {}
	}
	actual = { tag: Web.Tag.from_str(text).is_ok(), attribute: Web.AttrName.from_str(text).is_ok(), method: Web.Method.from_str(text).is_ok() }
	if actual != reference {
		crash "name grammar differs for ${Str.inspect(text)}: ${Str.inspect(actual)}, reference ${Str.inspect(reference)}"
	}
	{}
}

## Corpus input facts, the independent model and all three validators agree.
expect {
	for case in NameCorpus.cases {
		check_names(Corpus(case))
	}
	True
}

test : Input -> Fuzz.Outcome
test = |input| {
	check_names(input)
	Fuzz.keep
}

target = Fuzz.target_with({
	name: "names",
	examples: NameCorpus.cases.map(|case| Fuzz.example({ name: case.name, revision: "1", make: || Corpus(case) })).concat([
		Fuzz.example({ name: "generated-ascii-shape", revision: "1", make: || Generated("a=b") }),
		Fuzz.example({ name: "generated-unicode-shape", revision: "1", make: || Generated("é=a") }),
	]),
	generator: |arbitrary| {
		next = Fuzz.str(arbitrary)
		{ state: next.state, value: Generated(next.value) }
	},
	test,
	show: Str.inspect,
})
