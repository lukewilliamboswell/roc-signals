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

		## Check a literal with the same local-name grammar as computed text.
		from_quote : Str -> Try(Tag, [BadQuotedBytes(Str)])
		from_quote = |text| Tag.from_str(text).map_err(|NotATag(note)| BadQuotedBytes(note))

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

		## Literals also direct class and test-id names to their dedicated builders.
		## from_str remains available when an app explicitly intends those names.
		from_quote : Str -> Try(AttrName, [BadQuotedBytes(Str)])
		from_quote = |text| {
			if text == "class" {
				return Err(BadQuotedBytes("set `class` with Engine.class or Engine.class_s"))
			}
			if text == "data-testid" {
				return Err(BadQuotedBytes("set `data-testid` with Engine.test_id or Engine.test_id_s"))
			}
			AttrName.from_str(text).map_err(|NotAnAttribute(note)| BadQuotedBytes(note))
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
