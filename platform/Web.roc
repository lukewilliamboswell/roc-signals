import parser.Html as MarkupHtml
import parser.Svg as MarkupSvg
import parser.MathML as MarkupMathML

## Names used by DOM construction, event listeners and HTTP requests. Literals
## are checked while compiling; from_str validates names assembled by an app.
## Computed names remain valid when their grammar is well formed, without a
## browser vocabulary list.
## Namespace-specific tag restrictions also depend on the eventual DOM context.
## Event types must be nonempty by platform policy, though the DOM allows empty.
## Each value retains its original spelling; these types never normalize it.
Web := [].{

	## An element local name. Validation checks the DOM grammar, not which
	## elements a browser knows or the namespace in which one will be created.
	Tag :: Str.{

		## Check an authored name without restricting unknown or custom elements.
		from_str : Str -> Try(Tag, [NotATag(Str)])
		from_str = |text| match text.to_utf8() {
			[] => Err(NotATag("${Str.inspect(text)} is not an element name: a name must not be empty"))
			[first, ..] if is_ascii_alpha(first) => if text.to_utf8().all(|byte| !is_ascii_whitespace(byte) and byte != 0 and byte != '/' and byte != '>') {
				Ok(Tag.(text))
			} else Err(NotATag("${Str.inspect(text)} is not an element name: it holds ASCII whitespace, NUL, / or >, which the DOM refuses"))
			[first, ..] if first == ':' or first == '_' or first >= 128 => if text.to_utf8().all(|byte| is_ascii_alpha(byte) or (byte >= '0' and byte <= '9') or "-.:_".to_utf8().contains(byte) or byte >= 128) {
				Ok(Tag.(text))
			} else Err(NotATag("${Str.inspect(text)} is not an element name: after this initial character only letters, digits, -, ., :, _, and non-ASCII characters are allowed"))
			_ => Err(NotATag("${Str.inspect(text)} is not an element name: an element's name starts with a letter, :, _, or a non-ASCII character"))
		}

		## Literals name a listed HTML or exact-case SVG element, or a custom
		## element with a hyphen. from_str keeps grammar-only access to other names.
		from_quote : Str -> Try(Tag, [BadQuotedBytes(Str)])
		from_quote = |text| {
			tag = Tag.from_str(text).map_err(|NotATag(note)| BadQuotedBytes(note))?
			if MarkupHtml.Vocabulary.elements.contains(MarkupHtml.ascii_lower(text)) or MarkupSvg.Vocabulary.elements.contains(text) or text.contains("-") {
				return Ok(tag)
			}
			if MarkupMathML.Vocabulary.elements.contains(text) {
				return Err(BadQuotedBytes("<${text}> is a MathML element, which Engine.element does not create in its namespace; write MathML in a markup literal. Web.Tag.from_str(${Str.inspect(text)}) writes it as an unknown HTML element"))
			}
			hint = suggestion(text, MarkupHtml.Vocabulary.elements.concat(MarkupSvg.Vocabulary.elements))
			Err(BadQuotedBytes("<${text}> is not an HTML or SVG element in the pinned roc-parser vocabulary;${hint} a custom element's name holds a hyphen; any other name is written Web.Tag.from_str(${Str.inspect(text)})"))
		}

		## Recover the exact authored spelling for a boundary or an application log.
		text : Tag -> Str
		text = |Tag.(text)| text

		## Names are equal exactly when their retained text is equal.
		is_eq : _
	}

	## An attribute local name, independent of its element and namespace.
	AttrName :: Str.{

		## Check only the DOM grammar, including explicitly computed class names.
		from_str : Str -> Try(AttrName, [NotAnAttribute(Str)])
		from_str = |text| if (is_attribute(text)) Ok(AttrName.(text)) else Err(NotAnAttribute("${Str.inspect(text)} is not a valid attribute local name"))

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
			if text.starts_with("aria-") and !MarkupHtml.Vocabulary.aria_attributes.contains(text) {
				hint = suggestion(text, MarkupHtml.Vocabulary.aria_attributes)
				return Err(BadQuotedBytes("${Str.inspect(text)} is not an ARIA attribute in the pinned roc-parser vocabulary;${hint} one newer than the pinned vocabulary is written Web.AttrName.from_str(${Str.inspect(text)})"))
			}
			Ok(name)
		}

		## Recover the exact authored spelling for a boundary or an application log.
		text : AttrName -> Str
		text = |AttrName.(text)| text

		## Names are equal exactly when their retained text is equal.
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

## Suggestions read only parser-owned names. Equal edit distances prefer the
## same initial letter, then lexical order, independent of catalogue ordering.
suggestion : Str, List(Str) -> Str
suggestion = |text, names| {
	folded = MarkupHtml.ascii_lower(text)
	first = folded.to_utf8().first()
	best = names.fold(
		{ distance: 3.U64, initial: False, name: "" },
		|kept, name| {
			candidate = MarkupHtml.ascii_lower(name)
			distance = edit_distance(folded.to_utf8(), candidate.to_utf8())
			initial = candidate.to_utf8().first() == first
			prefer = distance < kept.distance or (distance == kept.distance and (initial and !kept.initial or (initial == kept.initial and lexical_before(name, kept.name))))
			if distance <= 2 and prefer {
				{ distance, initial, name }
			} else kept
		},
	)
	if best.distance <= 2 {
		" did you mean ${Str.inspect(best.name)}?"
	} else ""
}

## A literal-only optimal-string-alignment distance over folded UTF-8: an
## adjacent transposition counts as one edit, as do insertion, deletion and
## substitution. The length bound skips names outside the two-edit limit.
edit_distance : List(U8), List(U8) -> U64
edit_distance = |left, right| {
	if left.len() > right.len() {
		if left.len() - right.len() > 2 {
			return 3
		}
	} else if right.len() - left.len() > 2 {
		return 3
	}
	var $previous = [0.U64]
	var $initial_column = 0.U64
	for _ in right {
		$initial_column = $initial_column + 1
		$previous = $previous.append($initial_column)
	}
	var $before_previous = [0.U64]
	var $row = 0.U64
	for a in left {
		$row = $row + 1
		var $current = [$row]
		var $column = 0.U64
		for b in right {
			$column = $column + 1
			above = $previous.get($column) ?? crash "Web.edit_distance: previous row has every column"
			beside = $current.get($column - 1) ?? crash "Web.edit_distance: current row has preceding column"
			diagonal = $previous.get($column - 1) ?? crash "Web.edit_distance: previous row has preceding column"
			replace = diagonal + (if (a == b) 0 else 1)
			var $distance = minimum(replace, minimum(above + 1, beside + 1))
			if $row > 1 and $column > 1 {
				prior_a = left.get($row - 2) ?? crash "Web.edit_distance: prior left byte is in range"
				prior_b = right.get($column - 2) ?? crash "Web.edit_distance: prior right byte is in range"
				if a == prior_b and b == prior_a {
					before = $before_previous.get($column - 2) ?? crash "Web.edit_distance: prior diagonal is in range"
					$distance = minimum($distance, before + 1)
				}
			}
			$current = $current.append($distance)
		}
		$before_previous = $previous
		$previous = $current
	}
	$previous.last() ?? crash "Web.edit_distance: even an empty name has column zero"
}

minimum : U64, U64 -> U64
minimum = |left, right| if (left < right) left else right

lexical_before : Str, Str -> Bool
lexical_before = |left, right| {
	a = left.to_utf8()
	b = right.to_utf8()
	var $index = 0.U64
	for byte in a {
		other = b.get($index) ?? return False
		if byte != other {
			return byte < other
		}
		$index = $index + 1
	}
	a.len() < b.len()
}

## The parser owns the complete catalogue: every exported HTML/SVG/ARIA name
## remains usable, while HTML membership preserves case-insensitive spelling.
expect {
	MarkupHtml.Vocabulary.elements.all(|name| Web.Tag.from_quote(name).is_ok() and Web.Tag.from_str(name).is_ok()) and
		MarkupSvg.Vocabulary.elements.all(|name| Web.Tag.from_quote(name).is_ok() and Web.Tag.from_str(name).is_ok()) and
			MarkupHtml.Vocabulary.aria_attributes.all(|name| Web.AttrName.from_quote(name).is_ok() and Web.AttrName.from_str(name).is_ok()) and
				Web.Tag.from_quote("DIV")?.text() == "DIV" and Web.Tag.from_quote("foreignObject")?.text() == "foreignObject"
}

## Catalogue overlap and hyphens follow the acceptance order. annotation-xml
## is MathML vocabulary but the custom-name escape precedes that diagnostic;
## accepting its spelling does not create a MathML namespace.
expect {
	MarkupHtml.Vocabulary.elements.contains("a") and MarkupSvg.Vocabulary.elements.contains("a") and
		Web.Tag.from_quote("a").is_ok() and Web.Tag.from_quote("my-new-widget").is_ok() and
			MarkupMathML.Vocabulary.elements.contains("annotation-xml") and Web.Tag.from_quote("annotation-xml").is_ok() and
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
	suggestion("dvi", MarkupHtml.Vocabulary.elements) == " did you mean \"div\"?" and
		suggestion("aria-lable", MarkupHtml.Vocabulary.aria_attributes) == " did you mean \"aria-label\"?" and
			suggestion("lineargradient", MarkupSvg.Vocabulary.elements) == " did you mean \"linearGradient\"?" and
				suggestion("zzzzzzzzzzzzzzzzzzzz", MarkupHtml.Vocabulary.elements).is_empty() and
					suggestion("cat", ["bat", "cap"]) == suggestion("cat", ["cap", "bat"]) and
						suggestion("cat", ["bat", "cap"]) == " did you mean \"cap\"?" and
							suggestion("cat", ["can", "cap"]) == " did you mean \"can\"?"
}

## Each allowed edit has one cost; a swap is not a special case for any name.
expect {
	edit_distance("dvi".to_utf8(), "div".to_utf8()) == 1 and
		edit_distance("aria-lable".to_utf8(), "aria-label".to_utf8()) == 1 and
			edit_distance("dv".to_utf8(), "div".to_utf8()) == 1 and
				edit_distance("diiv".to_utf8(), "div".to_utf8()) == 1 and
					edit_distance("dov".to_utf8(), "div".to_utf8()) == 1 and
						edit_distance("".to_utf8(), "".to_utf8()) == 0 and
							edit_distance("div".to_utf8(), "div".to_utf8()) == 0 and
								edit_distance("xxxx".to_utf8(), "div".to_utf8()) > 2
}

## Authored near misses exercise the actual pinned catalogue, including exact
## SVG case. These cases are examples, not another element vocabulary.
expect {
	pairs = [("dvi", "div"), ("spna", "span"), ("butotn", "button"), ("inpt", "input"), ("texarea", "textarea"), ("selec", "select"), ("optoin", "option"), ("lable", "label"), ("artcle", "article"), ("sectoin", "section"), ("heder", "header"), ("foooter", "footer"), ("mian", "main"), ("nva", "nav"), ("imgg", "img"), ("canavs", "canvas"), ("svgg", "svg"), ("lineargradient", "linearGradient"), ("foreignobject", "foreignObject"), ("cricle", "circle")]
	names = MarkupHtml.Vocabulary.elements.concat(MarkupSvg.Vocabulary.elements)
	pairs.all(|(typo, word)| Web.Tag.from_quote(typo).is_err() and suggestion(typo, names) == " did you mean ${Str.inspect(word)}?")
}

## The strict and near-miss-only rules are remeasured against parser data.
## This fixed comparison includes fourteen listed/custom names and eleven
## grammar-valid names that need the explicit raw door under the strict rule.
expect {
	names = ["div", "span", "button", "input", "textarea", "select", "a", "svg", "linearGradient", "foreignObject", "my-widget", "section", "article", "nav", "math", "mi", "center", "marquee", "frame", "frameset", "font", "big", "geolocation", "fencedframe", "h7"]
	catalogue = MarkupHtml.Vocabulary.elements.concat(MarkupSvg.Vocabulary.elements)
	strict_refused = names.keep_if(|name| Web.Tag.from_quote(name).is_err()).len()
	near_miss_refused = names.keep_if(|name| Web.Tag.from_quote(name).is_err() and !suggestion(name, catalogue).is_empty()).len()
	strict_refused == 11 and near_miss_refused == 7 and names.all(|name| Web.Tag.from_str(name).is_ok())
}
