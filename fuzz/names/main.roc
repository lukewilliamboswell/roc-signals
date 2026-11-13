app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}
import fz.Fuzz
import pf.Web
import pf.Dom
import NameModel
import NameCorpus
import NamespaceModel
import NamespaceCorpus

Input : [Corpus(NameCorpus.Case), Generated(Str), NamespacedCase(NamespaceCorpus.Case), GeneratedNamespace(NamespaceModel.Name)]

## Grammar decisions must match an independent model. Fixed cases also pin
## that model to the input facts checked against real DOM and Fetch APIs.
check_names : Input -> {}
check_names = |input| match input {
	NamespacedCase(case) => {
		if NamespaceModel.accepts(case.input) != case.expected {
			crash "expanded-name model differs from measured case ${case.name}"
		}
		check_namespace(case.input)
	}
	GeneratedNamespace(name) => check_namespace(name)
	_ => check_raw_names(input)
}

## Raw-name grammar remains an independent property beside qualification.
check_raw_names : Input -> {}
check_raw_names = |input| {
	text = match input {
		Corpus(case) => case.text
		Generated(value) => value
		_ => crash "name target routed a qualified input to its raw property"
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

## Qualifying a checked local name preserves explicit URI/prefix/local facts.
## Builtin namespace tags and Uri aliases must give identical public values.
check_namespace : NamespaceModel.Name -> {}
check_namespace = |name| {
	namespace = match name.uri {
		"" => None
		"http://www.w3.org/1999/xhtml" => Html
		"http://www.w3.org/2000/svg" => Svg
		"http://www.w3.org/1998/Math/MathML" => MathML
		uri => Uri(uri)
	}
	prefix = match name.prefix {
		Unprefixed => Unprefixed
		Prefixed(value) => Prefix(value)
	}
	tag = match Web.Tag.from_str(name.local) {
		Err(error) => Err(error)
		Ok(local) => local.in_namespace({ namespace, prefix })
	}
	attribute = match Web.AttrName.from_str(name.local) {
		Err(error) => Err(error)
		Ok(local) => local.in_namespace({ namespace, prefix })
	}
	actual = { tag: tag.is_ok(), attribute: attribute.is_ok() }
	if actual != NamespaceModel.accepts(name) {
		crash "expanded-name constructor differs for ${Str.inspect(name)}: ${Str.inspect(actual)}"
	}
	written = match name.prefix {
		Unprefixed => name.local
		Prefixed(value) => "${value}:${name.local}"
	}
	match tag {
		Ok(value) => {
			Dom.validate_name(
				{
					namespace: name.uri,
					prefix: match name.prefix {
						Unprefixed => ""
						Prefixed(text) => text
					},
					local: name.local,
				},
				True,
			)
			if value.local() != name.local or value.prefix() != prefix or value.namespace() != Explicit(namespace) or value.text() != written {
				crash "element qualification changed expanded identity"
			}
			alias = (Web.Tag.from_str(name.local) ?? crash "accepted element lost its local name").in_namespace({ namespace: Uri(name.uri), prefix: prefix })
			if alias != Ok(value) {
				crash "namespace URI alias changed element identity"
			}
		}
		Err(_) => {}
	}
	match attribute {
		Ok(value) => {
			if value.local() != name.local or value.prefix() != prefix or value.namespace() != namespace or value.text() != written or !value.is_qualified() {
				crash "attribute qualification changed expanded identity or exact intent"
			}
			alias = (Web.AttrName.from_str(name.local) ?? crash "accepted attribute lost its local name").in_namespace({ namespace: Uri(name.uri), prefix: prefix })
			if alias != Ok(value) {
				crash "namespace URI alias changed attribute identity"
			}
		}
		Err(_) => {}
	}
	{}
}

## Corpus input facts, the independent model and all three validators agree.
expect {
	for case in NameCorpus.cases {
		check_names(Corpus(case))
	}
	for case in NamespaceCorpus.cases {
		check_names(NamespacedCase(case))
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
	examples: NameCorpus.cases.map(|case| Fuzz.example({ name: case.name, revision: "2", make: || Corpus(case) })).concat([
		Fuzz.example({ name: "generated-ascii-shape", revision: "2", make: || Generated("a=b") }),
		Fuzz.example({ name: "generated-unicode-shape", revision: "2", make: || Generated("é=a") }),
	]).concat(NamespaceCorpus.cases.map(|case| Fuzz.example({ name: case.name, revision: "1", make: || NamespacedCase(case) }))),
	generator: |arbitrary| {
		choice = Fuzz.u8(arbitrary)
		next = Fuzz.str(choice.state)
		if choice.value % 2 == 0 {
			return { state: next.state, value: Generated(next.value) }
		}
		prefix = Fuzz.str(next.state)
		uri = Fuzz.u8(prefix.state)
		spaces = ["", "http://www.w3.org/1999/xhtml", "http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML", "http://www.w3.org/XML/1998/namespace", "http://www.w3.org/2000/xmlns/", "urn:entry", "urn:a&b\"c<d\t\n\r"]
		selected = spaces.get(uri.value.to_u64() % spaces.len()) ?? crash "bounded namespace selection escaped its vocabulary"
		{ state: uri.state, value: GeneratedNamespace({ uri: selected, prefix: if (choice.value % 4 == 1) Unprefixed else Prefixed(prefix.value), local: next.value }) }
	},

	test,
	show: Str.inspect,
})
