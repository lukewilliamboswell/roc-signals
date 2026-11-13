import "expanded.tsv" as source : Str
import NamespaceModel
import NameCorpus

## Input facts shared with real Chrome, independently of Web's constructors.
## A dash distinguishes no prefix from an explicitly empty invalid prefix.
NamespaceCorpus := [].{
	Case : { name : Str, input : NamespaceModel.Name, expected : NamespaceModel.Flags }

	cases : List(Case)
	cases = source.split_on("\n").keep_if(|line| !line.is_empty()).map(
		|line| {
			match line.split_on("\t") {
				[name, flags, uri, prefix, local] => {
					bits = flags.to_utf8()
					if bits.len() != 2 or !bits.all(|byte| byte == '0' or byte == '1') {
						crash "expanded-name corpus requires two flags"
					}
					{ name, input: { uri: NameCorpus.decode_hex(uri), prefix: if (prefix == "-") Unprefixed else Prefixed(NameCorpus.decode_hex(prefix)), local: NameCorpus.decode_hex(local) }, expected: { tag: (bits.get(0) ?? crash "two flags") == '1', attribute: (bits.get(1) ?? crash "two flags") == '1' } }
				}
				_ => crash "expanded-name corpus requires five columns"
			}
		},
	)
}

## Every independently measured expanded-name fact also constrains the model,
## even when an earlier production constructor case has failed separately.
expect NamespaceCorpus.cases.all(|case| NamespaceModel.accepts(case.input) == case.expected)
