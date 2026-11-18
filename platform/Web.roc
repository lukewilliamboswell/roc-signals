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

	## A link destination whose explicit scheme is HTTP, HTTPS, mailto or tel,
	## or a relative reference. This checks scheme policy only: it establishes
	## no hostname validity, reachability or trustworthiness. Raw attributes and
	## unsafe HTML remain explicit unchecked paths.
	Link :: Str.{

		## Check computed text using browser URL preprocessing for scheme detection:
		## trim C0 controls and spaces, remove TAB/LF/CR, and fold ASCII case.
		## Accepted text is retained exactly, including its authored whitespace.
		from_str : Str -> Try(Link, [UnsupportedScheme(Str)])
		from_str = |authored| {
			bytes = authored.to_utf8()
			var $start = 0.U64
			var $end = bytes.len()
			while $start < $end and (bytes.get($start) ?? crash "Web.Link: start") <= 32 {
				$start = $start + 1
			}
			while $end > $start and (bytes.get($end - 1) ?? crash "Web.Link: end") <= 32 {
				$end = $end - 1
			}
			cleaned = bytes.sublist({ start: $start, len: $end - $start }).keep_if(|byte| byte != 9 and byte != 10 and byte != 13)
			match cleaned {
				[first, ..] if is_ascii_alpha(first) => {
					var $scheme = []
					for byte in cleaned {
						if byte == ':' {
							name = Str.from_utf8($scheme) ?? crash "Web.Link: ASCII scheme"
							return if (["http", "https", "mailto", "tel"].contains(name)) Ok(Link.(authored)) else Err(UnsupportedScheme(name))
						}
						if !(is_ascii_alpha(byte) or (byte >= '0' and byte <= '9') or byte == '+' or byte == '-' or byte == '.') {
							return Ok(Link.(authored))
						}
						$scheme = $scheme.append(if (byte >= 'A' and byte <= 'Z') byte + 32 else byte)
					}
				}
				_ => {}
			}
			Ok(Link.(authored))
		}

		## A literal follows the same policy; a rejected scheme fails compilation.
		from_quote : Str -> Try(Link, [BadQuotedBytes(Str)])
		from_quote = |authored| Link.from_str(authored).map_err(|UnsupportedScheme(scheme)| BadQuotedBytes("unsupported link scheme ${Str.inspect(scheme)}; use a relative reference, http, https, mailto or tel"))

		## The accepted authored destination, without normalization or resolution.
		text : Link -> Str
		text = |Link.(authored)| authored

		## Equality compares retained authored text, not resolved browser URLs.
		is_eq : _
	}

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
		from_str = |spelling| match spelling.to_utf8() {
			[] => Err(NotATag("${Str.inspect(spelling)} is not an element name: a name must not be empty"))
			[first, ..] if is_ascii_alpha(first) => if spelling.to_utf8().all(|byte| !is_ascii_whitespace(byte) and byte != 0 and byte != '/' and byte != '>') {
				Ok(Tag.({ local: spelling, namespace: Inherit, prefix: Unprefixed }))
			} else Err(NotATag("${Str.inspect(spelling)} is not an element name: it holds ASCII whitespace, NUL, / or >, which the DOM refuses"))
			[first, ..] if first == ':' or first == '_' or first >= 128 => if spelling.to_utf8().all(|byte| is_ascii_alpha(byte) or (byte >= '0' and byte <= '9') or "-.:_".to_utf8().contains(byte) or byte >= 128) {
				Ok(Tag.({ local: spelling, namespace: Inherit, prefix: Unprefixed }))
			} else Err(NotATag("${Str.inspect(spelling)} is not an element name: after this initial character only letters, digits, -, ., :, _, and non-ASCII characters are allowed"))
			_ => Err(NotATag("${Str.inspect(spelling)} is not an element name: an element's name starts with a letter, :, _, or a non-ASCII character"))
		}

		## Literals name a listed HTML or exact-case SVG element, or a custom
		## element with a hyphen. A literal holding a colon must also start with
		## an ASCII letter and hold no ASCII capitals, the names a raw
		## constructor can create under `<svg>` as well as in HTML. from_str
		## keeps grammar-only access to other names; a computed colon name
		## outside that rule is a contract error where it is created under SVG.
		from_quote : Str -> Try(Tag, [BadQuotedBytes(Str)])
		from_quote = |spelling| {
			tag = Tag.from_str(spelling).map_err(|NotATag(note)| BadQuotedBytes(note))?
			bytes = spelling.to_utf8()
			if spelling.contains(":") and (bytes.any(|byte| byte >= 'A' and byte <= 'Z') or !is_ascii_alpha(bytes.first() ?? 0)) {
				return Err(BadQuotedBytes("<${spelling}> holds a colon, which SVG keeps as local text only in a name that starts with an ASCII letter and holds no ASCII capitals; write ${Str.inspect(Spelling.ascii_lower(spelling))} if it starts with a letter (HTML folds it to that name), or qualify the name with Web.Tag.in_namespace"))
			}
			if MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml")).contains(Spelling.ascii_lower(spelling)) or MarkupFacts.element_names(Uri("http://www.w3.org/2000/svg")).contains(spelling) or spelling.contains("-") {
				return Ok(tag)
			}
			if MarkupFacts.element_names(Uri("http://www.w3.org/1998/Math/MathML")).contains(spelling) {
				return Err(BadQuotedBytes("<${spelling}> is a MathML element, which Engine.element does not create in its namespace; write MathML in a markup literal. Web.Tag.from_str(${Str.inspect(spelling)}) writes it as an unknown HTML element"))
			}
			hint = Spelling.suggest(spelling, MarkupFacts.element_names(Uri("http://www.w3.org/1999/xhtml")).concat(MarkupFacts.element_names(Uri("http://www.w3.org/2000/svg"))))
			Err(BadQuotedBytes("<${spelling}> is not an HTML or SVG element in the pinned roc-parser vocabulary;${hint} a custom element's name holds a hyphen; any other name is written Web.Tag.from_str(${Str.inspect(spelling)})"))
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
		from_str = |spelling| if (is_attribute(spelling)) Ok(AttrName.({ local: spelling, namespace: None, prefix: Unprefixed, exact: False })) else Err(NotAnAttribute("${Str.inspect(spelling)} is not a valid attribute local name"))

		## Literals check aria-* names against the parser's ARIA vocabulary and
		## direct class and test-id names to their dedicated builders. An HTML
		## element folds an attribute name's ASCII case, so these rules apply
		## to the folded spelling: `"CLASS"` is `class` and `"ARIA-LABLE"` is a
		## misspelt ARIA name. A correct ARIA name in another case is refused
		## with its lowercase spelling, because SVG and MathML elements keep the
		## case and read no ARIA attribute from it; the literal does not know
		## its element. Other names keep their case (`viewBox`). from_str keeps
		## grammar-only access to explicitly computed names. Event-handler
		## names such as `onclick` are not refused here.
		from_quote : Str -> Try(AttrName, [BadQuotedBytes(Str)])
		from_quote = |spelling| {
			folded = Spelling.ascii_lower(spelling)
			if ["data-roc-frame", "data-roc-node", "data-roc-children"].contains(folded) {
				return Err(BadQuotedBytes("${Str.inspect(spelling)} is reserved for startup transport; a foreign namespaced attribute needs explicit from_str and in_namespace construction"))
			}
			read_as = if (folded == spelling) "" else "an HTML element reads ${Str.inspect(spelling)} as ${Str.inspect(folded)}: "
			if folded == "class" {
				return Err(BadQuotedBytes("${read_as}set `class` with Engine.class or Engine.class_s"))
			}
			if folded == "data-testid" {
				return Err(BadQuotedBytes("${read_as}set `data-testid` with Engine.test_id or Engine.test_id_s"))
			}
			name = AttrName.from_str(spelling).map_err(|NotAnAttribute(note)| BadQuotedBytes(note))?
			if folded.starts_with("aria-") {
				if !MarkupFacts.aria_attribute_names.contains(folded) {
					hint = Spelling.suggest(spelling, MarkupFacts.aria_attribute_names)
					return Err(BadQuotedBytes("${Str.inspect(spelling)} is not an ARIA attribute in the pinned roc-parser vocabulary;${hint} one newer than the pinned vocabulary is written Web.AttrName.from_str(${Str.inspect(spelling)})"))
				}
				if folded != spelling {
					return Err(BadQuotedBytes("write ${Str.inspect(folded)}: ARIA attribute names are lowercase, and an SVG or MathML element keeps ${Str.inspect(spelling)} as written, so no ARIA attribute is set"))
				}
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

	## An open event type for a text handler (`on`, `on_with`): any nonempty
	## name without a retired suffix that a text handler can hear. There is
	## no known-event vocabulary, so a custom name (`"x:y"`) is one. One rule
	## serves a literal, checked while compiling, and a computed name, so an
	## event type the app holds never fails at mount.
	EventType :: Str.{

		## A computed event type, or `NotAnEventType` saying why it is not
		## one: an empty name, a retired `:prevent` or `:files` suffix, or
		## `keydown`/`keyup`, which a text handler never hears.
		from_str : Str -> Try(EventType, [NotAnEventType(Str)])
		from_str = |spelling| {
			if spelling.is_empty() {
				return Err(NotAnEventType("the platform requires a nonempty event type"))
			}
			if spelling.ends_with(":prevent") {
				return Err(NotAnEventType("`:prevent` is retired: write on_with(${Str.inspect(spelling.drop_suffix(":prevent"))}, { prevent: True }, handler)"))
			}
			if spelling.ends_with(":files") {
				return Err(NotAnEventType("`:files` is retired: listen for files with on_files(Change, handler), on_files(Drop, handler) or on_files(Paste, handler)"))
			}
			if ["keydown", "keyup"].contains(spelling) {
				return Err(NotAnEventType("a text handler never hears ${Str.inspect(spelling)}: listen for keys with on_key or on_document_key"))
			}
			Ok(EventType.(spelling))
		}

		## A literal event type, checked while compiling by the same rule as
		## `from_str`.
		from_quote : Str -> Try(EventType, [BadQuotedBytes(Str)])
		from_quote = |spelling| EventType.from_str(spelling).map_err(|NotAnEventType(note)| BadQuotedBytes(note))

		## Recover the exact authored spelling for a boundary or an application log.
		text : EventType -> Str
		text = |EventType.(spelling)| spelling

		## Names are equal exactly when their retained text is equal.
		is_eq : _
	}

	## A Fetch method token, excluding the three methods Fetch refuses.
	Method :: Str.{

		## Validate Fetch's grammar and forbidden methods, preserving original case.
		from_str : Str -> Try(Method, [NotAMethod(Str)])
		from_str = |spelling| {
			if !is_method(spelling) {
				return Err(NotAMethod("${Str.inspect(spelling)} is not an HTTP method: a method is one or more token characters"))
			}
			if ["CONNECT", "TRACE", "TRACK"].contains(ascii_upper(spelling)) {
				return Err(NotAMethod("the browser refuses to send a ${ascii_upper(spelling)} request"))
			}
			Ok(Method.(spelling))
		}

		## Reject a lower-case spelling Fetch would preserve rather than normalize.
		## Computed methods still use from_str, which applies only Fetch's rules.
		from_quote : Str -> Try(Method, [BadQuotedBytes(Str)])
		from_quote = |spelling| {
			method = Method.from_str(spelling).map_err(|NotAMethod(note)| BadQuotedBytes(note))?
			upper = ascii_upper(spelling)
			if spelling.to_utf8().any(|byte| byte >= 'a' and byte <= 'z') and !["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"].contains(upper) {
				Err(BadQuotedBytes("write ${Str.inspect(upper)}: the browser upper-cases only DELETE, GET, HEAD, OPTIONS, POST and PUT"))
			} else Ok(method)
		}

		## Recover the exact authored spelling for a boundary or an application log.
		text : Method -> Str
		text = |Method.(spelling)| spelling

		## Names are equal exactly when their retained text is equal.
		is_eq : _
	}

	## A method that carries a request body, for `File.upload`: a Fetch
	## method (`Method`'s rules) other than `GET` and `HEAD` in any ASCII
	## case, which carry none and so cannot send a file. A literal
	## (`method: "PUT"`) is checked while compiling.
	UploadMethod :: Str.{

		## A computed method, `NotAMethod` when it is not one Fetch sends, or
		## `NoBody` for `GET` and `HEAD`, whose requests carry no body.
		from_str : Str -> Try(UploadMethod, [NotAMethod(Str), NoBody(Str)])
		from_str = |spelling| {
			_ = Method.from_str(spelling)?
			upper = ascii_upper(spelling)
			if ["GET", "HEAD"].contains(upper) {
				return Err(NoBody("${upper} carries no body, so it cannot upload a file"))
			}
			Ok(UploadMethod.(spelling))
		}

		## A literal method, checked while compiling by `Method`'s literal
		## rule and the body rule of `from_str`.
		from_quote : Str -> Try(UploadMethod, [BadQuotedBytes(Str)])
		from_quote = |spelling| {
			_ = Method.from_quote(spelling)?
			match UploadMethod.from_str(spelling) {
				Ok(method) => Ok(method)
				Err(NotAMethod(note)) | Err(NoBody(note)) => Err(BadQuotedBytes(note))
			}
		}

		## The exact spelling sent.
		text : UploadMethod -> Str
		text = |UploadMethod.(spelling)| spelling

		## Methods are equal exactly when their retained text is equal.
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
		patch_literal: Web.Method.from_quote("patch").is_err(),
		patch_computed: Web.Method.from_str("patch").is_ok(),
	} == { class_literal: True, test_id_literal: True, patch_literal: True, patch_computed: True }
}

## A computed event type is refused by the rule a literal is refused by,
## so no event type an app holds can fail at mount.
expect {
	refused = |spelling| match Web.EventType.from_str(spelling) {
		Ok(_) => "accepted"
		Err(NotAnEventType(note)) => note
	}
	{
		prevent: refused("click:prevent"),
		files: refused("change:files"),
		key: refused("keydown"),
		literal_key: Web.EventType.from_quote("keyup").is_err(),
		custom: refused("x:y"),
	} == {
		prevent: "`:prevent` is retired: write on_with(\"click\", { prevent: True }, handler)",
		files: "`:files` is retired: listen for files with on_files(Change, handler), on_files(Drop, handler) or on_files(Paste, handler)",
		key: "a text handler never hears \"keydown\": listen for keys with on_key or on_document_key",
		literal_key: True,
		custom: "accepted",
	}
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

## An upload method carries a body: GET and HEAD are refused in any case,
## computed or literal, and any other method keeps its spelling.
expect {
	{
		get: Web.UploadMethod.from_str("get"),
		head: Web.UploadMethod.from_quote("HeAd").is_err(),
		trace: Web.UploadMethod.from_str("TRACE").is_err(),
		put: Web.UploadMethod.from_quote("PUT")?.text(),
		custom: Web.UploadMethod.from_str("propfind")?.text(),
	} == { get: Err(NoBody("GET carries no body, so it cannot upload a file")), head: True, trace: True, put: "PUT", custom: "propfind" }
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

## A tag literal holding a colon is one a raw constructor can create under SVG.
expect {
	["A:b-c", ":a-b", "_x:y-z"].all(|name| Web.Tag.from_quote(name).is_err() and Web.Tag.from_str(name).is_ok()) and Web.Tag.from_quote("a:b-c").is_ok()
}

## An HTML element folds attribute case, so literal rules see the folded name.
## Mixed-case ARIA names point to their lowercase spelling, explicit text keeps
## its grammar-only door, and other foreign names keep their exact case.
expect {
	["ARIA-LABLE", "CLASS", "Class", "DATA-TESTID", "aria-Label", "ARIA-LABEL"].all(|name| Web.AttrName.from_quote(name).is_err() and Web.AttrName.from_str(name).is_ok()) and
		Web.AttrName.from_quote("aria-Label") == Err(BadQuotedBytes("write \"aria-label\": ARIA attribute names are lowercase, and an SVG or MathML element keeps \"aria-Label\" as written, so no ARIA attribute is set")) and
			Web.AttrName.from_quote("viewBox").is_ok() and Web.AttrName.from_quote("aria-label").is_ok() and Web.AttrName.from_quote("onclick").is_ok()
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

## Checked destinations retain accepted input and reject obfuscated schemes.
expect {
	accepted = ["", "../guide", "//example.test", "#part", "?q=a:b", "/a:b", " HTTPs://example.test ", "mail\nto:a@b", "tel:+123", "1x:relative", "a/b:relative", "é:relative"]
	accepted.all(
		|text| match Web.Link.from_str(text) {
			Ok(link) => link.text() == text
			Err(_) => False
		},
	) and
		["javascript:alert(1)", " JaVa\tScRiPt:alert(1) ", "\u(0000)data:text/html,x\u(001F)", "vbscript:x", "blob:x", "file:///x", "x+y.z:x"].all(|text| Web.Link.from_str(text).is_err())
}

## Literal transport names cannot masquerade as authored startup annotations.
## A separately namespaced attribute with the same local spelling is ordinary.
expect {
	reserved = ["data-roc-frame", "data-roc-node", "data-roc-children", "DATA-ROC-NODE"]
	foreign = Web.AttrName.from_str("data-roc-node")?.in_namespace({ namespace: Uri("urn:app") })?
	reserved.all(|name| Web.AttrName.from_quote(name).is_err()) and foreign.namespace() == Uri("urn:app")
}
