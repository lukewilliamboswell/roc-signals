import parser.MarkupFacts
import Spelling

## Names used by DOM construction, event listeners and HTTP requests. Literals
## are checked while compiling; from_str validates names assembled by an app.
## Computed names remain valid when their grammar is well formed, without a
## browser vocabulary list.
## Namespace-specific tag restrictions also depend on the eventual DOM context.
## Event types must be nonempty by platform policy, though the DOM allows empty.
## Each value retains its original spelling; these types never normalize it.
Web := [].{

	## An explicit element or attribute namespace. Uri keeps extension namespaces
	## available without adding them to the platform's vocabulary. An empty URI
	## has the DOM's no-namespace meaning.
	Namespace : [Html, Svg, MathML, None, Uri(Str)]

	## An expanded name's prefix. It is separate from its local name: a colon in
	## an unqualified HTML name does not establish a namespace or prefix.
	Prefix : [Unprefixed, Prefix(Str)]

	## Explicit expanded-name construction. The local name stays on the checked
	## receiver; omitting prefix preserves an unprefixed identity, even if that
	## local text itself contains a colon.
	NameProps := { namespace : Namespace, prefix : Prefix ?? Unprefixed }

	## An element name. Computed text checks DOM grammar; literals also use the
	## parser's HTML and SVG vocabulary. Raw names inherit construction context;
	## in_namespace supplies explicit namespace, prefix and local identity.
	Tag :: { local : Str, namespace : [Inherit, Explicit(Namespace)], prefix : Prefix }.{

		## Check an authored name without restricting unknown or custom elements.
		from_str : Str -> Try(Tag, [NotATag(Str)])
		from_str = |text| match text.to_utf8() {
			[] => Err(NotATag("${Str.inspect(text)} is not an element name: a name must not be empty"))
			[first, ..] if is_ascii_alpha(first) => if text.to_utf8().all(|byte| !is_ascii_whitespace(byte) and byte != 0 and byte != '/' and byte != '>') {
				Ok(Tag.({ local: text, namespace: Inherit, prefix: Unprefixed }))
			} else Err(NotATag("${Str.inspect(text)} is not an element name: it holds ASCII whitespace, NUL, / or >, which the DOM refuses"))
			[first, ..] if first == ':' or first == '_' or first >= 128 => if text.to_utf8().all(|byte| is_ascii_alpha(byte) or (byte >= '0' and byte <= '9') or "-.:_".to_utf8().contains(byte) or byte >= 128) {
				Ok(Tag.({ local: text, namespace: Inherit, prefix: Unprefixed }))
			} else Err(NotATag("${Str.inspect(text)} is not an element name: after this initial character only letters, digits, -, ., :, _, and non-ASCII characters are allowed"))
			_ => Err(NotATag("${Str.inspect(text)} is not an element name: an element's name starts with a letter, :, _, or a non-ASCII character"))
		}

		## Literals name a listed HTML or exact-case SVG element, or a custom
		## element with a hyphen. from_str keeps grammar-only access to other names.
		from_quote : Str -> Try(Tag, [BadQuotedBytes(Str)])
		from_quote = |text| {
			tag = Tag.from_str(text).map_err(|NotATag(note)| BadQuotedBytes(note))?
			if MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml")).contains(Spelling.ascii_lower(text)) or MarkupFacts.element_names(Uri("http://www.w3.org/2000/svg")).contains(text) or text.contains("-") {
				return Ok(tag)
			}
			if MarkupFacts.element_names(Uri("http://www.w3.org/1998/Math/MathML")).contains(text) {
				return Err(BadQuotedBytes("<${text}> is a MathML element, which Engine.element does not create in its namespace; write MathML in a markup literal. Web.Tag.from_str(${Str.inspect(text)}) writes it as an unknown HTML element"))
			}
			hint = Spelling.suggest(text, MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml")).concat(MarkupFacts.element_names(Uri("http://www.w3.org/2000/svg"))))
			Err(BadQuotedBytes("<${text}> is not an HTML or SVG element in the pinned roc-parser vocabulary;${hint} a custom element's name holds a hyphen; any other name is written Web.Tag.from_str(${Str.inspect(text)})"))
		}

		## Recover the exact authored spelling for a boundary or an application log.
		text : Tag -> Str
		text = |Tag.(name)| written_name(name.local, name.prefix)

		## The local spelling, independent of a prefix. Raw HTML names may themselves
		## contain a colon, which remains local text until explicitly qualified.
		local : Tag -> Str
		local = |Tag.(name)| name.local

		## Whether construction inherits the raw svg/foreignObject context or
		## uses an explicit namespace. Moving a drawn element never changes this.
		namespace : Tag -> [Inherit, Explicit(Namespace)]
		namespace = |Tag.(name)| name.namespace

		## The explicitly supplied prefix; raw constructors supply none.
		prefix : Tag -> Prefix
		prefix = |Tag.(name)| name.prefix

		## Qualify this local name with explicit namespace facts. This checks modern
		## DOM name and reserved xml/xmlns rules, not XML QName vocabulary. Prefix
		## and local spelling remain separate. Verified empty-node factories also
		## preserve unprefixed foreign colon names and bare xmlns extension names;
		## facts those factories cannot retain return a typed error.
		in_namespace : Tag, NameProps -> Try(Tag, [NotATag(Str)])
		in_namespace = |Tag.(name), props| {
			ns = normalized_namespace(props.namespace)
			selected_prefix = props.prefix
			check_qualified(name.local, ns, selected_prefix, True).map_err(|note| NotATag(note))?
			Ok(Tag.({ local: name.local, namespace: Explicit(ns), prefix: selected_prefix }))
		}

		## Names compare by their local spelling, namespace selection and prefix.
		is_eq : _
	}

	## An attribute name, unnamespaced until explicitly qualified. Its text alone
	## never supplies a prefix or namespace.
	AttrName :: { local : Str, namespace : Namespace, prefix : Prefix, exact : Bool }.{

		## Check only the DOM grammar, including explicitly computed class names.
		from_str : Str -> Try(AttrName, [NotAnAttribute(Str)])
		from_str = |text| if (is_attribute(text)) Ok(AttrName.({ local: text, namespace: None, prefix: Unprefixed, exact: False })) else Err(NotAnAttribute("${Str.inspect(text)} is not a valid attribute local name"))

		## Literals check aria-* names against the parser's ARIA vocabulary and
		## direct class and test-id names to their dedicated builders. from_str
		## keeps grammar-only access to explicitly computed names.
		from_quote : Str -> Try(AttrName, [BadQuotedBytes(Str)])
		from_quote = |text| {
			if text == "class" {
				return Err(BadQuotedBytes("set `class` with Engine.class or Engine.class_s"))
			}
			if text == "data-testid" {
				return Err(BadQuotedBytes("set `data-testid` with Engine.test_id or Engine.test_id_s"))
			}
			name = AttrName.from_str(text).map_err(|NotAnAttribute(note)| BadQuotedBytes(note))?
			if text.starts_with("aria-") and !MarkupFacts.aria_attribute_names.contains(text) {
				hint = Spelling.suggest(text, MarkupFacts.aria_attribute_names)
				return Err(BadQuotedBytes("${Str.inspect(text)} is not an ARIA attribute in the pinned roc-parser vocabulary;${hint} one newer than the pinned vocabulary is written Web.AttrName.from_str(${Str.inspect(text)})"))
			}
			Ok(name)
		}

		## Recover the exact authored spelling for a boundary or an application log.
		text : AttrName -> Str
		text = |AttrName.(name)| written_name(name.local, name.prefix)

		## The local spelling used with its namespace to identify this attribute.
		## An unqualified raw name retains its complete text, including any colon.
		local : AttrName -> Str
		local = |AttrName.(name)| name.local

		## The explicit namespace, or None for ordinary raw attributes.
		namespace : AttrName -> Namespace
		namespace = |AttrName.(name)| name.namespace

		## The explicit prefix retained when the attribute is set.
		prefix : AttrName -> Prefix
		prefix = |AttrName.(name)| name.prefix

		## Explicit qualification preserves exact local case. Raw names instead
		## follow the eventual element's HTML attribute-name case folding.
		is_qualified : AttrName -> Bool
		is_qualified = |AttrName.(name)| name.exact

		## Qualify a local attribute name without guessing a namespace from its
		## text. Checks DOM namespace pairings; values and vocabulary stay separate.
		in_namespace : AttrName, NameProps -> Try(AttrName, [NotAnAttribute(Str)])
		in_namespace = |AttrName.(name), props| {
			ns = normalized_namespace(props.namespace)
			selected_prefix = props.prefix
			check_qualified(name.local, ns, selected_prefix, False).map_err(|note| NotAnAttribute(note))?
			Ok(AttrName.({ local: name.local, namespace: ns, prefix: selected_prefix, exact: True }))
		}

		## Names compare local spelling, namespace, prefix and raw/exact construction intent.
		is_eq : _
	}

	## An open event type. The platform requires a nonempty name and keeps the
	## engine's mount checks for computed retired suffixes and text key handlers.
	EventType :: Str.{

		## Accept any nonempty computed type; there is no known-event vocabulary.
		from_str : Str -> Try(EventType, [NotAnEventType(Str)])
		from_str = |text| if (text.is_empty()) Err(NotAnEventType("the platform requires a nonempty event type")) else Ok(EventType.(text))

		## Move the engine's retired-suffix and text-key rules to the literal.
		from_quote : Str -> Try(EventType, [BadQuotedBytes(Str)])
		from_quote = |text| {
			if text.ends_with(":prevent") {
				return Err(BadQuotedBytes("`:prevent` is retired: write on_with(${Str.inspect(text.drop_suffix(":prevent"))}, { prevent: True }, handler)"))
			}
			if text.ends_with(":files") {
				return Err(BadQuotedBytes("`:files` is retired: listen for files with on_files(Change, handler), on_files(Drop, handler) or on_files(Paste, handler)"))
			}
			if ["keydown", "keyup"].contains(text) {
				return Err(BadQuotedBytes("a text handler never hears ${Str.inspect(text)}: listen for keys with on_key or on_document_key"))
			}
			EventType.from_str(text).map_err(|NotAnEventType(note)| BadQuotedBytes(note))
		}

		## Recover the exact authored spelling for a boundary or an application log.
		text : EventType -> Str
		text = |EventType.(text)| text

		## Names are equal exactly when their retained text is equal.
		is_eq : _
	}

	## A Fetch method token, excluding the three methods Fetch refuses.
	Method :: Str.{

		## Validate Fetch's grammar and forbidden methods, preserving original case.
		from_str : Str -> Try(Method, [NotAMethod(Str)])
		from_str = |text| {
			if !is_method(text) {
				return Err(NotAMethod("${Str.inspect(text)} is not an HTTP method: a method is one or more token characters"))
			}
			if ["CONNECT", "TRACE", "TRACK"].contains(ascii_upper(text)) {
				return Err(NotAMethod("the browser refuses to send a ${ascii_upper(text)} request"))
			}
			Ok(Method.(text))
		}

		## Reject a lower-case spelling Fetch would preserve rather than normalize.
		## Computed methods still use from_str, which applies only Fetch's rules.
		from_quote : Str -> Try(Method, [BadQuotedBytes(Str)])
		from_quote = |text| {
			method = Method.from_str(text).map_err(|NotAMethod(note)| BadQuotedBytes(note))?
			upper = ascii_upper(text)
			if text.to_utf8().any(|byte| byte >= 'a' and byte <= 'z') and !["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"].contains(upper) {
				Err(BadQuotedBytes("write ${Str.inspect(upper)}: the browser upper-cases only DELETE, GET, HEAD, OPTIONS, POST and PUT"))
			} else Ok(method)
		}

		## Recover the exact authored spelling for a boundary or an application log.
		text : Method -> Str
		text = |Method.(text)| text

		## Names are equal exactly when their retained text is equal.
		is_eq : _
	}
}

is_ascii_alpha : U8 -> Bool
is_ascii_alpha = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z')

is_ascii_whitespace : U8 -> Bool
is_ascii_whitespace = |byte| [9.U8, 10, 12, 13, 32].contains(byte)

is_attribute : Str -> Bool
is_attribute = |text| !text.is_empty() and text.to_utf8().all(|byte| !is_ascii_whitespace(byte) and byte != 0 and byte != '/' and byte != '=' and byte != '>')

is_method : Str -> Bool
is_method = |text| !text.is_empty() and text.to_utf8().all(|byte| is_ascii_alpha(byte) or (byte >= '0' and byte <= '9') or "!#$%&'*+-.^_`|~".to_utf8().contains(byte))

ascii_upper : Str -> Str
ascii_upper = |text| Str.from_utf8(text.to_utf8().map(|byte| if (byte >= 'a' and byte <= 'z') byte - 32 else byte)) ?? crash "Web.ascii_upper: ASCII case conversion preserves UTF-8"

## Unknown but well-formed names keep their exact spelling through from_str.
expect {
	{
		tag: Web.Tag.from_str("my-widget")?.text(),
		attribute: Web.AttrName.from_str("class")?.text(),
		event: Web.EventType.from_str("vendor:ready")?.text(),
		method: Web.Method.from_str("patch")?.text(),
	} == { tag: "my-widget", attribute: "class", event: "vendor:ready", method: "patch" }
}

## Literal-only rules do not close the computed-name escape door.
expect {
	{
		class_literal: Web.AttrName.from_quote("class").is_err(),
		test_id_literal: Web.AttrName.from_quote("data-testid").is_err(),
		retired_literal: Web.EventType.from_quote("click:prevent").is_err(),
		retired_computed: Web.EventType.from_str("click:prevent").is_ok(),
		key_literal: Web.EventType.from_quote("keydown").is_err(),
		key_computed: Web.EventType.from_str("keydown").is_ok(),
		patch_literal: Web.Method.from_quote("patch").is_err(),
		patch_computed: Web.Method.from_str("patch").is_ok(),
	} == { class_literal: True, test_id_literal: True, retired_literal: True, retired_computed: True, key_literal: True, key_computed: True, patch_literal: True, patch_computed: True }
}

## Ordinary method spellings that Fetch normalizes remain legal literals;
## forbidden methods are refused in every case, through either constructor.
expect {
	{
		lower_get: Web.Method.from_quote("get")?.text(),
		mixed_post: Web.Method.from_quote("PoSt")?.text(),
		computed_trace: Web.Method.from_str("tRaCe").is_err(),
		literal_connect: Web.Method.from_quote("connect").is_err(),
		empty: Web.Method.from_str("").is_err(),
		space: Web.Method.from_str("GE T").is_err(),
	} == { lower_get: "get", mixed_post: "PoSt", computed_trace: True, literal_connect: True, empty: True, space: True }
}

## The nonempty event rule is the platform's own, not a DOM restriction.
expect Web.EventType.from_str("").is_err() and Web.EventType.from_quote("").is_err()

## The parser owns the complete catalogue: every exported HTML/SVG/ARIA name
## remains usable, while HTML membership preserves case-insensitive spelling.
expect {
	MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml")).all(|name| Web.Tag.from_quote(name).is_ok() and Web.Tag.from_str(name).is_ok()) and
		MarkupFacts.element_names(Uri("http://www.w3.org/2000/svg")).all(|name| Web.Tag.from_quote(name).is_ok() and Web.Tag.from_str(name).is_ok()) and
			MarkupFacts.aria_attribute_names.all(|name| Web.AttrName.from_quote(name).is_ok() and Web.AttrName.from_str(name).is_ok()) and
				Web.Tag.from_quote("DIV")?.text() == "DIV" and Web.Tag.from_quote("foreignObject")?.text() == "foreignObject"
}

## Catalogue overlap and hyphens follow the acceptance order. annotation-xml
## is MathML vocabulary but the custom-name escape precedes that diagnostic;
## accepting its spelling does not create a MathML namespace.
expect {
	MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml")).contains("a") and MarkupFacts.element_names(Uri("http://www.w3.org/2000/svg")).contains("a") and
		Web.Tag.from_quote("a").is_ok() and Web.Tag.from_quote("my-new-widget").is_ok() and
			MarkupFacts.element_names(Uri("http://www.w3.org/1998/Math/MathML")).contains("annotation-xml") and Web.Tag.from_quote("annotation-xml").is_ok() and
				Web.Tag.from_quote("-widget").is_err() and Web.Tag.from_quote("my widget-name").is_err() and
					Web.Tag.from_quote("math").is_err() and Web.Tag.from_str("math").is_ok()
}

## Only literals depend on the current catalogue. Explicit grammar-checked
## text admits new, obsolete and MathML names and future ARIA spellings.
expect {
	["dvi", "geolocation", "center", "math", "lineargradient"].all(|name| Web.Tag.from_quote(name).is_err() and Web.Tag.from_str(name).is_ok()) and
		Web.AttrName.from_quote("aria-lable").is_err() and Web.AttrName.from_str("aria-lable").is_ok() and
			Web.AttrName.from_str("aria-future-proposal").is_ok() and Web.AttrName.from_quote("data-future-proposal").is_ok()
}

## Suggestions use the threshold, case folding, initial-letter and lexical
## tie rules; supplied candidate order never selects a different answer.
expect {
	Spelling.suggest("dvi", MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml"))) == " did you mean \"div\"?" and
		Spelling.suggest("aria-lable", MarkupFacts.aria_attribute_names) == " did you mean \"aria-label\"?" and
			Spelling.suggest("lineargradient", MarkupFacts.element_names(Uri("http://www.w3.org/2000/svg"))) == " did you mean \"linearGradient\"?" and
				Spelling.suggest("zzzzzzzzzzzzzzzzzzzz", MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml"))).is_empty() and
					Spelling.suggest("cat", ["bat", "cap"]) == Spelling.suggest("cat", ["cap", "bat"]) and
						Spelling.suggest("cat", ["bat", "cap"]) == " did you mean \"cap\"?" and
							Spelling.suggest("cat", ["can", "cap"]) == " did you mean \"can\"?"
}

## Each allowed edit has one cost; a swap is not a special case for any name.
expect {
	Spelling.distance("dvi".to_utf8(), "div".to_utf8()) == 1 and
		Spelling.distance("aria-lable".to_utf8(), "aria-label".to_utf8()) == 1 and
			Spelling.distance("dv".to_utf8(), "div".to_utf8()) == 1 and
				Spelling.distance("diiv".to_utf8(), "div".to_utf8()) == 1 and
					Spelling.distance("dov".to_utf8(), "div".to_utf8()) == 1 and
						Spelling.distance("".to_utf8(), "".to_utf8()) == 0 and
							Spelling.distance("div".to_utf8(), "div".to_utf8()) == 0 and
								Spelling.distance("xxxx".to_utf8(), "div".to_utf8()) > 2
}

## Authored near misses exercise the actual pinned catalogue, including exact
## SVG case. These cases are examples, not another element vocabulary.
expect {
	pairs = [("dvi", "div"), ("spna", "span"), ("butotn", "button"), ("inpt", "input"), ("texarea", "textarea"), ("selec", "select"), ("optoin", "option"), ("lable", "label"), ("artcle", "article"), ("sectoin", "section"), ("heder", "header"), ("foooter", "footer"), ("mian", "main"), ("nva", "nav"), ("imgg", "img"), ("canavs", "canvas"), ("svgg", "svg"), ("lineargradient", "linearGradient"), ("foreignobject", "foreignObject"), ("cricle", "circle")]
	names = MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml")).concat(MarkupFacts.element_names(Uri("http://www.w3.org/2000/svg")))
	pairs.all(|(typo, word)| Web.Tag.from_quote(typo).is_err() and Spelling.suggest(typo, names) == " did you mean ${Str.inspect(word)}?")
}

## The strict and near-miss-only rules are remeasured against parser data.
## This fixed comparison includes fourteen listed/custom names and eleven
## grammar-valid names that need the explicit raw door under the strict rule.
expect {
	names = ["div", "span", "button", "input", "textarea", "select", "a", "svg", "linearGradient", "foreignObject", "my-widget", "section", "article", "nav", "math", "mi", "center", "marquee", "frame", "frameset", "font", "big", "geolocation", "fencedframe", "h7"]
	catalogue = MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml")).concat(MarkupFacts.element_names(Uri("http://www.w3.org/2000/svg")))
	strict_refused = names.keep_if(|name| Web.Tag.from_quote(name).is_err()).len()
	near_miss_refused = names.keep_if(|name| Web.Tag.from_quote(name).is_err() and !Spelling.suggest(name, catalogue).is_empty()).len()
	strict_refused == 11 and near_miss_refused == 7 and names.all(|name| Web.Tag.from_str(name).is_ok())
}

## Namespace URI spelling is data, not a catalogue lookup. The DOM treats an
## empty URI as no namespace, so equal construction facts have one spelling.
normalized_namespace : Web.Namespace -> Web.Namespace
normalized_namespace = |namespace| match namespace {
	Uri("") => None
	Uri("http://www.w3.org/1999/xhtml") => Html
	Uri("http://www.w3.org/2000/svg") => Svg
	Uri("http://www.w3.org/1998/Math/MathML") => MathML
	_ => namespace
}

## Keep prefix identity separate from local text. This is called only after
## construction has established which part is a prefix.
written_name : Str, Web.Prefix -> Str
written_name = |local, prefix| match prefix {
	Unprefixed => local
	Prefix(value) => "${value}:${local}"
}

## DOM Standard section 1.4 deliberately permits more than XML QNames. The
## prefix/local split is already explicit; reject an unrepresentable split
## rather than letting a DOM factory split a different first colon.
check_qualified : Str, Web.Namespace, Web.Prefix, Bool -> Try({}, Str)
check_qualified = |local, namespace, prefix, element| {
	written = written_name(local, prefix)
	match prefix {
		Prefix(value) => {
			if value.is_empty() or value.to_utf8().any(|byte| is_ascii_whitespace(byte) or byte == 0 or byte == '/' or byte == '>' or byte == ':') {
				return Err("${Str.inspect(written)} has an invalid or unrepresentable namespace prefix")
			}
			if namespace == None {
				return Err("${Str.inspect(written)} has a prefix without a namespace")
			}
			if value == "xml" and namespace != Uri("http://www.w3.org/XML/1998/namespace") {
				return Err("the xml prefix requires the XML namespace")
			}
		}
		Unprefixed => {
			if element and (namespace == Html or namespace == Svg or namespace == MathML) and local.contains(":") and local.to_utf8().any(|unit| unit >= 'A' and unit <= 'Z') {
				return Err("an unprefixed HTML, SVG or MathML colon local name cannot preserve uppercase through its empty-node factory")
			}
			if element and (namespace == Svg or namespace == MathML) and local.contains(":") and !is_ascii_alpha(local.to_utf8().first() ?? crash "checked nonempty local name") {
				return Err("an unprefixed SVG or MathML colon local name must begin with an ASCII letter for its empty-node factory")
			}
			# Direct or verified empty-node factories retain local colon text;
			# a namespace-aware qualified-name factory would split it instead.
			if local.contains(":") and !((element and (namespace == Html or namespace == Svg or namespace == MathML or namespace == None)) or (!element and namespace == None)) {
				return Err("${Str.inspect(local)} requires an explicit prefix and local name in this namespace")
			}
		}
	}
	xmlns = namespace == Uri("http://www.w3.org/2000/xmlns/")
	declares = written == "xmlns" or prefix == Prefix("xmlns")
	# An ordinary raw xmlns attribute is allowed by setAttribute, like other
	# unqualified raw text; explicit namespace declarations stay distinct.
	ordinary = prefix == Unprefixed and ((element and (namespace == Html or namespace == None)) or (!element and namespace == None))
	bare_xmlns = element and prefix == Unprefixed and local == "xmlns"
	if !ordinary and !bare_xmlns and xmlns != declares {
		return Err("xmlns names require the XMLNS namespace, and only xmlns names use it")
	}
	if bare_xmlns and !ordinary and !xmlns {
		uri = match namespace {
			Svg => "http://www.w3.org/2000/svg"
			MathML => "http://www.w3.org/1998/Math/MathML"
			Uri(value) => value
			_ => crash "nonordinary xmlns namespace"
		}
		if uri == "http://www.w3.org/XML/1998/namespace" or !xml_factory_uri(uri) {
			return Err("this unprefixed xmlns element cannot preserve its namespace through the empty-node factory")
		}
	}
	Ok({})
}

## Only the XML empty-node fallback needs XML 1.0 character data. Ordinary
## DOM factories keep their broader namespace URI contract. Valid Roc strings
## exclude surrogates; these are the remaining XML Char exclusions.
xml_factory_uri : Str -> Bool
xml_factory_uri = |uri| !uri.to_utf8().any(|byte| byte < 32 and byte != 9 and byte != 10 and byte != 13) and !uri.contains("\u(FFFE)") and !uri.contains("\u(FFFF)")

## Explicit namespace qualification retains the prefix, URI and local name,
## including extension namespaces unknown to the HTML/SVG catalogue.
expect {
	name = Web.Tag.from_str("entry")?.in_namespace({ namespace: Uri("urn:entry"), prefix: Prefix("e") })?
	name.local() == "entry" and name.text() == "e:entry" and name.prefix() == Prefix("e") and name.namespace() == Explicit(Uri("urn:entry"))
}

## A raw colon-bearing attribute never guesses XLink identity, while an
## explicitly qualified name retains a different local name and namespace.
expect {
	raw = Web.AttrName.from_str("xlink:href")?
	qualified = Web.AttrName.from_str("href")?.in_namespace({ namespace: Uri("http://www.w3.org/1999/xlink"), prefix: Prefix("xlink") })?
	raw.text() == qualified.text() and raw.local() == "xlink:href" and qualified.local() == "href" and raw != qualified
}

## Modern DOM accepts equals in element local names and numeric prefixes;
## qualification must not accidentally substitute XML NCName grammar.
expect {
	Web.Tag.from_str("a=b")?.in_namespace({ namespace: Svg }).is_ok() and
		Web.Tag.from_str("a")?.in_namespace({ namespace: Svg, prefix: Prefix("1") }).is_ok() and
			Web.Tag.from_str("b:c")?.in_namespace({ namespace: Svg, prefix: Prefix("a") }).is_ok()
}

## Reserved namespace pairings fail as values before construction. XML's
## namespace may have another prefix; the reverse implication is not a rule.
expect {
	name = Web.AttrName.from_str("lang")?
	name.in_namespace({ namespace: Svg, prefix: Prefix("xml") }).is_err() and
		name.in_namespace({ namespace: Uri("http://www.w3.org/XML/1998/namespace"), prefix: Prefix("xml") }).is_ok() and
			name.in_namespace({ namespace: Uri("http://www.w3.org/XML/1998/namespace"), prefix: Prefix("p") }).is_ok() and
				name.in_namespace({ namespace: None, prefix: Prefix("p") }).is_err()
}

## XMLNS attributes retain their declaration identity, and empty URI follows
## the DOM's no-namespace conversion without changing the retained text.
expect {
	declaration = Web.AttrName.from_str("p")?.in_namespace({ namespace: Uri("http://www.w3.org/2000/xmlns/"), prefix: Prefix("xmlns") })?
	plain = Web.AttrName.from_str("name")?.in_namespace({ namespace: Uri("") })?
	declaration.text() == "xmlns:p" and plain.namespace() == None and Web.AttrName.from_str("name")?.in_namespace({ namespace: Uri("http://www.w3.org/2000/xmlns/") }).is_err()
}

## HTML local text containing a colon and a genuinely prefixed HTML name are
## distinct facts, even though their written qualified spelling is identical.
expect {
	local = Web.Tag.from_str("h:div")?.in_namespace({ namespace: Html })?
	prefixed = Web.Tag.from_str("div")?.in_namespace({ namespace: Html, prefix: Prefix("h") })?
	local.text() == prefixed.text() and local.local() == "h:div" and prefixed.local() == "div" and local != prefixed
}

## Named common namespaces and their literal URI aliases have one identity;
## changing only the public spelling must not create a different attribute.
expect {
	name = Web.AttrName.from_str("label")?
	name.in_namespace({ namespace: Svg }) == name.in_namespace({ namespace: Uri("http://www.w3.org/2000/svg") }) and
		Web.Tag.from_str("div")?.in_namespace({ namespace: Html }) == Web.Tag.from_str("div")?.in_namespace({ namespace: Uri("http://www.w3.org/1999/xhtml") })
}

## Qualification supplies exact attribute case, even with no namespace; raw
## construction keeps the HTML attribute-name folding requested by setAttribute.
expect {
	raw = Web.AttrName.from_str("data-UPPER")?
	exact = raw.in_namespace({ namespace: None })?
	!raw.is_qualified() and exact.is_qualified() and raw.local() == exact.local() and exact.local() == "data-UPPER"
}

## Non-NS DOM factories preserve xmlns and colon local names without inventing
## a prefix. These identities must not inherit NS-factory reserved-name rules.
expect {
	Web.Tag.from_str("xmlns")?.in_namespace({ namespace: None }).is_ok() and
		Web.Tag.from_str("a:UPPER")?.in_namespace({ namespace: None }).is_ok() and
			Web.AttrName.from_str("xmlns")?.in_namespace({ namespace: None }).is_ok() and
				Web.Tag.from_str("a:UPPER")?.in_namespace({ namespace: Html }).is_err()
}

## Omitting a prefix states an unprefixed identity rather than splitting local
## colon text, and is equal to spelling Unprefixed explicitly.
expect {
	name = Web.Tag.from_str("h:div")?
	name.in_namespace({ namespace: Html }) == name.in_namespace({ namespace: Html, prefix: Unprefixed })
}

## Foreign colon factories keep exact lowercase local text, while a genuine
## prefix remains a separate identity. Tokenization and case loss are refused.
expect {
	local = Web.Tag.from_str("h:a=b")?
	local.in_namespace({ namespace: Svg })?.local() == "h:a=b" and
		local.in_namespace({ namespace: MathML })?.prefix() == Unprefixed and
			Web.Tag.from_str("h:UPPER")?.in_namespace({ namespace: Svg }).is_err() and
				Web.Tag.from_str("é:x")?.in_namespace({ namespace: MathML }).is_err()
}

## XML-only restrictions apply to the bare xmlns empty-node fallback, never
## ordinary DOM namespace strings or a genuine XMLNS declaration element.
expect {
	name = Web.Tag.from_str("xmlns")?
	name.in_namespace({ namespace: Uri("urn:entry\t&<\"") }).is_ok() and
		name.in_namespace({ namespace: Uri("http://www.w3.org/XML/1998/namespace") }).is_err() and
			name.in_namespace({ namespace: Uri("urn:entry\u(0000)") }).is_err() and
				name.in_namespace({ namespace: Uri("urn:entry\u(FFFE)") }).is_err() and
					name.in_namespace({ namespace: Uri("urn:entry\u(1FFFE)") }).is_ok() and
						name.in_namespace({ namespace: Uri("http://www.w3.org/2000/xmlns/") }).is_ok() and
							Web.Tag.from_str("entry")?.in_namespace({ namespace: Uri("urn:entry\u(0000)") }).is_ok()
}
