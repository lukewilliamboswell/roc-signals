import NameModel

## Independent expanded-name facts. URI strings express namespace identity;
## prefixes and local text remain separate, including a colon without prefix.
## This model uses DOM grammar and the measured non-NS/empty-node factory facts,
## never Web's constructors, parser catalogue or runtime validation helpers.
NamespaceModel := [].{
	Prefix : [Unprefixed, Prefixed(Str)]
	Name : { uri : Str, prefix : Prefix, local : Str }
	Flags : { tag : Bool, attribute : Bool }

	## Ordinary local-name grammar is distinct from prefix and reserved-namespace
	## rules. Factory capability preserves expanded identity instead of guessing a
	## prefix from local text; the fixed cases are also checked in real Chrome.
	accepts : Name -> Flags
	accepts = |name| {
		grammar = NameModel.accepts(name.local)
		prefix_valid = match name.prefix {
			Unprefixed => True
			Prefixed(prefix) => !name.uri.is_empty() and !prefix.is_empty() and !prefix.to_utf8().any(|byte| [0.U8, 9, 10, 12, 13, 32, 47, 58, 62].contains(byte)) and (prefix != "xml" or name.uri == "http://www.w3.org/XML/1998/namespace")
		}
		if !prefix_valid {
			return { tag: False, attribute: False }
		}
		declares = match name.prefix {
			Unprefixed => name.local == "xmlns"
			Prefixed(prefix) => prefix == "xmlns"
		}
		xmlns = name.uri == "http://www.w3.org/2000/xmlns/"
		paired = xmlns == declares
		unprefixed = name.prefix == Unprefixed
		ordinary_attribute = unprefixed and name.uri.is_empty()
		# A verified XML empty-node factory preserves bare xmlns outside XMLNS,
		# except the reserved XML URI and URI data XML cannot represent. The
		# corresponding attribute still needs ordinary or real XMLNS identity.
		xml_characters = !name.uri.to_utf8().any(|byte| [0.U8, 1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31].contains(byte)) and !name.uri.contains("\u(FFFE)") and !name.uri.contains("\u(FFFF)")
		element_pair = paired or (unprefixed and name.local == "xmlns" and name.uri != "http://www.w3.org/XML/1998/namespace" and (name.uri.is_empty() or name.uri == "http://www.w3.org/1999/xhtml" or xml_characters))
		local_colon = name.local.contains(":")
		foreign = ["http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML"].contains(name.uri)
		first = name.local.to_utf8().first() ?? 0
		foreign_start = !foreign or "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".to_utf8().contains(first)
		element_factory = !unprefixed or !local_colon or (["", "http://www.w3.org/1999/xhtml", "http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML"].contains(name.uri) and foreign_start)
		folds_colon = unprefixed and ["http://www.w3.org/1999/xhtml", "http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML"].contains(name.uri) and local_colon and name.local.to_utf8().any(|byte| byte >= 65 and byte <= 90)
		attribute_factory = !unprefixed or !local_colon or ordinary_attribute
		{ tag: grammar.tag and element_pair and element_factory and !folds_colon, attribute: grammar.attribute and (paired or ordinary_attribute) and attribute_factory }
	}
}

## Prefix numbers/equality punctuation follow modern DOM rules, not XML NCName.
expect NamespaceModel.accepts({ uri: "urn:entry", prefix: Prefixed("1="), local: "entry" }) == { tag: True, attribute: True }

## A local colon can be data without supplying a prefix in no namespace.
expect NamespaceModel.accepts({ uri: "", prefix: Unprefixed, local: "x:UPPER" }) == { tag: True, attribute: True }

## Namespace-only reserved pairings remain distinct from unqualified xmlns.
expect NamespaceModel.accepts({ uri: "urn:entry", prefix: Prefixed("xmlns"), local: "entry" }) == { tag: False, attribute: False } and NamespaceModel.accepts({ uri: "", prefix: Unprefixed, local: "xmlns" }) == { tag: True, attribute: True }
