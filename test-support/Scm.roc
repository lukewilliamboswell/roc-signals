import JsonOut

## The `.scm` spec language: the one parser both spec runners use.
##
## A spec file holds exactly one form:
##
## ```scheme
## (test "name"
##   (setup ...)   ; optional, declarative pre-mount state
##   (steps ...))  ; required, at least one step
## ```
##
## `parse` turns the text into a typed `Spec`. Every malformed form, unknown
## head or bad argument is an `Err` naming its line and column; nothing is
## skipped, repaired or guessed. The native runner (`SpecRunner.roc`) executes
## the typed steps; `to_json` emits them for the browser runner, so the grammar
## is implemented once.
##
## The grammar is the web subset of the original native host's
## (`src/spec/spec_parser.zig`, `src/spec/sexpr.zig`): the GUI `scenario` form
## and its window steps are not part of it.
Scm := [].{

	## A source position, one-based.
	Pos : { line : U64, column : U64 }

	## A parse failure at a position.
	Problem : { pos : Pos, message : Str }

	## One s-expression with the position of its first character.
	Sx := [Sym(Str, Pos), Str(Str, Pos), Int(I64, Pos), Bool(Bool, Pos), List(List(Sx), Pos)]

	## Semantic locators. `Role` matches an element's explicit `role` or its
	## implicit role with its accessible name; `Label` its `aria-label`;
	## `Text` a text node whose content is exactly the string; `TestId` its
	## `data-testid`. Resolution is the runner's job.
	Loc : [Role({ role : Str, name : Str }), Label(Str), Text(Str), TestId(Str)]

	Visibility : [Visible, Hidden]

	Online : [Online, Offline]

	Header : { name : Str, value : Str }

	## What a stubbed HTTP request answers with.
	Stub : [
		Reply({ url : Str, status : U16, headers : List(Header), body : Str }),
		Reject({ kind : RejectKind, detail : Str }),
	]

	## How a stubbed request fails: the browser could not reach the server
	## (`network`, with the browser's message as `:detail`) or the request's
	## timeout expired (`timeout`). These are the failures the web runtime can
	## observe (design.md, "The effect channel").
	RejectKind : [Network, Timeout]

	## Declarative state applied before the app mounts.
	Setup : [
		ManualEffects,
		InitialLocation(Str),
		InitialVisibility(Visibility),
		InitialOnline(Online),
		LocalStorage({ key : Str, value : Str }),

		## Local storage cannot be used at all: every access throws, as in a
		## browser with site data disabled.
		LocalStorageUnavailable,
		SessionStorage({ key : Str, value : Str }),
		SeedHttp({ label : Str, stub : Stub }),
	]

	## A step a test takes, in order.
	##
	## A metric step names one of `metric_names` (design.md's work-assertion
	## table); any other name is a parse error.
	Op : [
		Click(Loc),
		RealClick(Loc),
		PointerDown(Loc),
		PointerUp(Loc),
		PointerEnter(Loc),
		PointerLeave(Loc),
		KeyDown({ target : Loc, key : Str, shift : Bool }),
		Focus(Loc),
		Blur(Loc),
		Change(Loc, Str),
		SelectOption(Loc, Str),
		CompositionStart(Loc),
		CompositionEnd(Loc),
		CustomEvent({ target : Loc, name : Str, detail : Str }),
		Submit(Loc),
		Fill(Loc, Str),
		Check(Loc),
		Uncheck(Loc),
		ExpectText(Loc, Str),
		ExpectVisible(Loc),
		ExpectAbsent(Loc),
		ExpectValue(Loc, Str),
		ExpectAttr({ target : Loc, name : Str, value : Str }),
		ExpectNoAttr({ target : Loc, name : Str }),
		ExpectChecked(Loc, Bool),
		ExpectDisabled(Loc, Bool),
		ExpectUpdates(Loc, U64),
		StubHttp({ label : Str, stub : Stub }),
		RunEffect(U64),
		ExpectPendingEffects(U64),
		TickInterval(U64),
		TickIntervalIfActive(U64),
		ExpectCleanup({ name : Str, count : U64 }),
		ExpectInterval({ period_ms : U64, count : U64 }),
		Navigate(Str),
		SetVisibility(Visibility),
		SetOnline(Online),
		HistoryBack,
		HistoryForward,
		ExpectLocation(Str),
		ExpectTitle(Str),
		ExpectLocalStorage({ key : Str, value : Str }),
		ExpectSessionStorage({ key : Str, value : Str }),
		ExpectNoLocalStorage(Str),
		ExpectNoSessionStorage(Str),
		MarkMetrics,
		ExpectMetricDelta({ metric : Str, delta : I64 }),
		ExpectMetricDeltaAtMost({ metric : Str, delta : I64 }),
	]

	## A step with the position of its form.
	Step : { op : Op, pos : Pos }

	## A parsed spec file.
	Spec : { name : Str, setup : List({ item : Setup, pos : Pos }), steps : List(Step) }

	## Parse one spec file's text.
	parse : Str -> Try(Spec, Problem)
	parse = |text| {
		root = Scm.read_one(text)?
		(items, pos) = match root {
			List(xs, p) => (xs, p)
			other => return Err({ pos: Scm.pos_of(other), message: "a spec is one (test \"name\" ...) form" })
		}
		head = items.get(0) ?? return Err({ pos, message: "a spec is one (test \"name\" ...) form" })
		if !Scm.is_sym(head, "test") {
			return Err({ pos: Scm.pos_of(head), message: "a spec starts with `test`; `scenario` and other forms are not part of the web grammar" })
		}
		name = match items.get(1) {
			Ok(Str(s, _)) => s
			Ok(other) => return Err({ pos: Scm.pos_of(other), message: "the test name must be a string" })
			Err(_) => return Err({ pos, message: "the test needs a name" })
		}
		var $setup = []
		var $steps = []
		var $saw_setup = Bool.False
		var $saw_steps = Bool.False
		for section in items.drop_first(2) {
			(forms, spos) = match section {
				List(xs, p) => (xs, p)
				other => return Err({ pos: Scm.pos_of(other), message: "expected a (setup ...) or (steps ...) section" })
			}
			first = forms.get(0) ?? return Err({ pos: spos, message: "empty section" })
			if Scm.is_sym(first, "setup") {
				if $saw_setup or $saw_steps {
					return Err({ pos: spos, message: "setup must come once, before steps" })
				}
				$saw_setup = Bool.True
				for form in forms.drop_first(1) {
					$setup = $setup.append(Scm.setup_form(form)?)
				}
			} else if Scm.is_sym(first, "steps") {
				if $saw_steps {
					return Err({ pos: spos, message: "steps must come once" })
				}
				$saw_steps = Bool.True
				if forms.len() == 1 {
					return Err({ pos: spos, message: "steps must hold at least one step" })
				}
				for form in forms.drop_first(1) {
					$steps = $steps.append(Scm.step_form(form)?)
				}
			} else {
				return Err({ pos: Scm.pos_of(first), message: "unknown section ${Scm.show(first)}; expected setup or steps" })
			}
		}
		if !$saw_steps {
			return Err({ pos, message: "the test has no (steps ...) section" })
		}
		Ok({ name, setup: $setup, steps: $steps })
	}

	## `path:line:column: message`, for reports.
	show_problem : Str, Problem -> Str
	show_problem = |path, { pos, message }| "${path}:${pos.line.to_str()}:${pos.column.to_str()}: ${message}"

	# ---------------------------------------------------------------- reader

	R : { bytes : List(U8), at : U64, line : U64, column : U64 }

	## Read exactly one top-level s-expression.
	read_one : Str -> Try(Sx, Problem)
	read_one = |text| {
		r0 = Scm.skip_trivia({ bytes: text.to_utf8(), at: 0, line: 1, column: 1 })
		if r0.at >= r0.bytes.len() {
			return Err({ pos: Scm.here(r0), message: "expected one s-expression" })
		}
		(sx, r1) = Scm.read_expr(r0)?
		r2 = Scm.skip_trivia(r1)
		if r2.at < r2.bytes.len() {
			return Err({ pos: Scm.here(r2), message: "expected exactly one top-level s-expression" })
		}
		Ok(sx)
	}

	here : R -> Pos
	here = |r| { line: r.line, column: r.column }

	peek : R -> Try(U8, [End])
	peek = |r| r.bytes.get(r.at).map_err(|_| End)

	## Step over one byte, tracking lines and columns. A UTF-8 continuation
	## byte does not start a column.
	advance : R -> R
	advance = |r|
		match r.bytes.get(r.at) {
			Ok('\n') => { ..r, at: r.at + 1, line: r.line + 1, column: 1 }
			Ok(b) if b >= 0x80 and b < 0xC0 => { ..r, at: r.at + 1 }
			_ => { ..r, at: r.at + 1, column: r.column + 1 }
		}

	skip_trivia : R -> R
	skip_trivia = |r0| {
		var $r = r0
		var $in_comment = Bool.False
		while $r.at < $r.bytes.len() {
			b = Scm.peek($r) ?? 0
			if $in_comment {
				if b == '\n' {
					$in_comment = Bool.False
				}
				$r = Scm.advance($r)
			} else if b == ' ' or b == '\t' or b == '\r' or b == '\n' {
				$r = Scm.advance($r)
			} else if b == ';' {
				$in_comment = Bool.True
				$r = Scm.advance($r)
			} else {
				return $r
			}
		}
		$r
	}

	read_expr : R -> Try((Sx, R), Problem)
	read_expr = |r0| {
		r = Scm.skip_trivia(r0)
		match Scm.peek(r) {
			Err(End) => Err({ pos: Scm.here(r), message: "unexpected end of file" })
			Ok('(') => Scm.read_list(r)
			Ok(')') => Err({ pos: Scm.here(r), message: "unexpected closing parenthesis" })
			Ok('"') => Scm.read_string(r)
			Ok(_) => Scm.read_atom(r)
		}
	}

	read_list : R -> Try((Sx, R), Problem)
	read_list = |r0| {
		start = Scm.here(r0)
		var $r = Scm.skip_trivia(Scm.advance(r0))
		var $items = []
		while Scm.peek($r) != Ok(')') {
			if $r.at >= $r.bytes.len() {
				return Err({ pos: start, message: "unterminated list" })
			}
			(item, next) = Scm.read_expr($r)?
			$items = $items.append(item)
			$r = Scm.skip_trivia(next)
		}
		Ok((List($items, start), Scm.advance($r)))
	}

	read_string : R -> Try((Sx, R), Problem)
	read_string = |r0| {
		start = Scm.here(r0)
		var $r = Scm.advance(r0)
		var $out = []
		while $r.at < $r.bytes.len() {
			b = Scm.peek($r) ?? 0
			if b == '"' {
				s = Str.from_utf8($out) ? |_| { pos: start, message: "string is not valid UTF-8" }
				return Ok((Str(s, start), Scm.advance($r)))
			} else if b == '\n' or b == '\r' {
				return Err({ pos: start, message: "strings cannot contain literal newlines" })
			} else if b == '\\' {
				esc_at = Scm.here($r)
				$r = Scm.advance($r)
				e = Scm.peek($r) ? |_| { pos: start, message: "unterminated string escape" }
				decoded = match e {
					'n' => '\n'
					'r' => '\r'
					't' => '\t'
					'"' => '"'
					'\\' => '\\'
					_ => return Err({ pos: esc_at, message: "unsupported string escape" })
				}
				$out = $out.append(decoded)
				$r = Scm.advance($r)
			} else {
				$out = $out.append(b)
				$r = Scm.advance($r)
			}
		}
		Err({ pos: start, message: "unterminated string" })
	}

	is_delimiter : U8 -> Bool
	is_delimiter = |b| b == ' ' or b == '\t' or b == '\r' or b == '\n' or b == '(' or b == ')' or b == '"' or b == ';'

	read_atom : R -> Try((Sx, R), Problem)
	read_atom = |r0| {
		start = Scm.here(r0)
		var $r = r0
		while $r.at < $r.bytes.len() and !Scm.is_delimiter(Scm.peek($r) ?? ' ') {
			$r = Scm.advance($r)
		}
		text = Str.from_utf8($r.bytes.sublist({ start: r0.at, len: $r.at - r0.at })) ? |_| { pos: start, message: "atom is not valid UTF-8" }
		atom = if text == "true" {
			Bool(Bool.True, start)
		} else if text == "false" {
			Bool(Bool.False, start)
		} else {
			match I64.from_str(text) {
				Ok(n) => Int(n, start)
				Err(_) => Sym(text, start)
			}
		}
		Ok((atom, $r))
	}

	# ------------------------------------------------------------ s-expr views

	pos_of : Sx -> Pos
	pos_of = |sx|
		match sx {
			Sym(_, p) => p
			Str(_, p) => p
			Int(_, p) => p
			Bool(_, p) => p
			List(_, p) => p
		}

	is_sym : Sx, Str -> Bool
	is_sym = |sx, want|
		match sx {
			Sym(s, _) => s == want
			_ => Bool.False
		}

	## How a form is spelled in a message.
	show : Sx -> Str
	show = |sx|
		match sx {
			Sym(s, _) => s
			Str(s, _) => "\"${s}\""
			Int(n, _) => n.to_str()
			Bool(b, _) => if (b) "true" else "false"
			List(xs, _) => "(${Str.join_with(xs.map(Scm.show), " ")})"
		}

	bad : Sx, Str -> Problem
	bad = |sx, message| { pos: Scm.pos_of(sx), message }

	string : Sx, Str -> Try(Str, Problem)
	string = |sx, what|
		match sx {
			Str(s, _) => Ok(s)
			_ => Err(Scm.bad(sx, "${what} must be a string, got ${Scm.show(sx)}"))
		}

	symbol : Sx, Str -> Try(Str, Problem)
	symbol = |sx, what|
		match sx {
			Sym(s, _) => Ok(s)
			_ => Err(Scm.bad(sx, "${what} must be a bare word, got ${Scm.show(sx)}"))
		}

	## A count or period: a non-negative integer.
	unsigned : Sx, Str -> Try(U64, Problem)
	unsigned = |sx, what|
		match sx {
			Int(n, _) if n >= 0 => Ok(n.to_u64_wrap())
			_ => Err(Scm.bad(sx, "${what} must be a non-negative integer, got ${Scm.show(sx)}"))
		}

	integer : Sx, Str -> Try(I64, Problem)
	integer = |sx, what|
		match sx {
			Int(n, _) => Ok(n)
			_ => Err(Scm.bad(sx, "${what} must be an integer, got ${Scm.show(sx)}"))
		}

	boolean : Sx, Str -> Try(Bool, Problem)
	boolean = |sx, what|
		match sx {
			Bool(b, _) => Ok(b)
			_ => Err(Scm.bad(sx, "${what} must be true or false, got ${Scm.show(sx)}"))
		}

	## A locator form: `(role button :name "Save")`, `(label "Email")`,
	## `(text "Loading")` or `(test-id "status")`.
	locator : Sx -> Try(Loc, Problem)
	locator = |sx| {
		items = match sx {
			List(xs, _) => xs
			_ => return Err(Scm.bad(sx, "expected a locator such as (label \"Email\"), got ${Scm.show(sx)}"))
		}
		kind = match items.get(0) {
			Ok(Sym(k, _)) => k
			_ => return Err(Scm.bad(sx, "a locator starts with role, label, text or test-id"))
		}
		if kind == "role" {
			match items {
				[_, r, key, Str(name, _)] if Scm.is_sym(key, ":name") => {
					role = match r {
						Sym(s, _) => s
						Str(s, _) => s
						_ => return Err(Scm.bad(r, "a role is a bare word"))
					}
					Ok(Role({ role, name }))
				}
				_ => Err(Scm.bad(sx, "a role locator is (role ROLE :name \"NAME\")"))
			}
		} else {
			value = match items {
				[_, Str(s, _)] => s
				_ => return Err(Scm.bad(sx, "a ${kind} locator is (${kind} \"VALUE\")"))
			}
			if kind == "label" {
				Ok(Label(value))
			} else if kind == "text" {
				Ok(Text(value))
			} else if kind == "test-id" {
				Ok(TestId(value))
			} else {
				Err(Scm.bad(sx, "unknown locator kind ${kind}; expected role, label, text or test-id"))
			}
		}
	}

	## The arguments of a form, checked to be exactly `n` long.
	arity : Sx, List(Sx), U64 -> Try(List(Sx), Problem)
	arity = |form, args, n|
		if args.len() == n {
			Ok(args)
		} else {
			Err(Scm.bad(form, "${Scm.head_of(form)} takes ${n.to_str()} argument(s), got ${args.len().to_str()}"))
		}

	head_of : Sx -> Str
	head_of = |form|
		match form {
			List([Sym(h, _), ..], _) => h
			_ => Scm.show(form)
		}

	arg : List(Sx), U64 -> Sx
	arg = |args, i| args.get(i) ?? crash "Scm.arg: arity was checked first"

	visibility : Sx -> Try(Visibility, Problem)
	visibility = |sx|
		match Scm.symbol(sx, "visibility")? {
			"visible" => Ok(Visible)
			"hidden" => Ok(Hidden)
			other => Err(Scm.bad(sx, "visibility is visible or hidden, got ${other}"))
		}

	online : Sx -> Try(Online, Problem)
	online = |sx|
		match Scm.symbol(sx, "connectivity")? {
			"online" => Ok(Online)
			"offline" => Ok(Offline)
			other => Err(Scm.bad(sx, "connectivity is online or offline, got ${other}"))
		}

	key_value : Sx, List(Sx) -> Try({ key : Str, value : Str }, Problem)
	key_value = |form, args0| {
		args = Scm.arity(form, args0, 2)?
		Ok({ key: Scm.string(Scm.arg(args, 0), "the key")?, value: Scm.string(Scm.arg(args, 1), "the value")? })
	}

	split_form : Sx -> Try((Str, List(Sx), Pos), Problem)
	split_form = |form|
		match form {
			List([Sym(h, _), .. as args], p) => Ok((h, args, p))
			List(_, _) => Err(Scm.bad(form, "a step starts with its name"))
			_ => Err(Scm.bad(form, "expected a step form, got ${Scm.show(form)}"))
		}

	setup_form : Sx -> Try({ item : Setup, pos : Pos }, Problem)
	setup_form = |form| {
		(head, args, pos) = Scm.split_form(form)?
		item = if head == "manual-effects" {
			_ = Scm.arity(form, args, 0)?
			ManualEffects
		} else if head == "initial-location" {
			InitialLocation(Scm.location(Scm.arg(Scm.arity(form, args, 1)?, 0))?)
		} else if head == "initial-visibility" {
			InitialVisibility(Scm.visibility(Scm.arg(Scm.arity(form, args, 1)?, 0))?)
		} else if head == "initial-online" {
			InitialOnline(Scm.online(Scm.arg(Scm.arity(form, args, 1)?, 0))?)
		} else if head == "local-storage" {
			LocalStorage(Scm.key_value(form, args)?)
		} else if head == "local-storage-unavailable" {
			_ = Scm.arity(form, args, 0)?
			LocalStorageUnavailable
		} else if head == "session-storage" {
			SessionStorage(Scm.key_value(form, args)?)
		} else if head == "stub-http" or head == "stub-http-reject" {
			SeedHttp(Scm.http_fixture(form, head, args)?)
		} else {
			return Err(Scm.bad(form, "unknown setup form ${head}"))
		}
		Ok({ item, pos })
	}

	## A location the app starts at or is navigated to: an absolute path,
	## optionally with a query and a hash.
	location : Sx -> Try(Str, Problem)
	location = |sx| {
		s = Scm.string(sx, "a location")?
		if (s.starts_with("/")) Ok(s) else Err(Scm.bad(sx, "a location starts with /, got \"${s}\""))
	}

	## `(stub-http "label" :url "..." :status N [:headers (("k" "v") ...)] :body "...")`
	## or `(stub-http-reject "label" :kind KIND :detail "...")`.
	http_fixture : Sx, Str, List(Sx) -> Try({ label : Str, stub : Stub }, Problem)
	http_fixture = |form, head, args| {
		label_sx = args.get(0) ? |_| Scm.bad(form, "${head} needs a label")
		label = Scm.string(label_sx, "the stub label")?
		if label == "" {
			return Err(Scm.bad(label_sx, "the stub label must not be empty"))
		}
		fields = Scm.keywords(form, args.drop_first(1))?
		if head == "stub-http-reject" {
			if fields.len() != 2 {
				return Err(Scm.bad(form, "stub-http-reject takes exactly :kind and :detail"))
			}
			kind_sx = Scm.required(form, fields, ":kind")?
			kind = match Scm.symbol(kind_sx, ":kind")? {
				"network" => Network
				"timeout" => Timeout
				other => return Err(Scm.bad(kind_sx, "unknown reject kind ${other}; a request fails with network or timeout"))
			}
			detail_sx = Scm.required(form, fields, ":detail")?
			detail = Scm.string(detail_sx, ":detail")?
			if kind == Timeout and detail != "" {
				return Err(Scm.bad(detail_sx, "a timeout has an empty :detail"))
			}
			Ok({ label, stub: Reject({ kind, detail }) })
		} else {
			url_sx = Scm.required(form, fields, ":url")?
			url = Scm.string(url_sx, ":url")?
			if url == "" {
				return Err(Scm.bad(url_sx, ":url must not be empty"))
			}
			status_sx = Scm.required(form, fields, ":status")?
			status = Scm.unsigned(status_sx, ":status")?
			if status < 100 or status > 999 {
				return Err(Scm.bad(status_sx, ":status must be 100 to 999"))
			}
			body = Scm.string(Scm.required(form, fields, ":body")?, ":body")?
			headers = match fields.find_first(|f| f.key == ":headers") {
				Ok(f) => Scm.header_list(f.value)?
				Err(_) => []
			}
			expected = if (fields.any(|f| f.key == ":headers")) 4 else 3
			if fields.len() != expected {
				return Err(Scm.bad(form, "stub-http takes :url, :status, :body and optionally :headers"))
			}
			Ok({ label, stub: Reply({ url, status: status.to_u16_wrap(), headers, body }) })
		}
	}

	## `:key value` pairs, each key at most once.
	keywords : Sx, List(Sx) -> Try(List({ key : Str, value : Sx }), Problem)
	keywords = |form, items| {
		if items.len() % 2 != 0 {
			return Err(Scm.bad(form, "keyword arguments come in :key value pairs"))
		}
		var $out = []
		var $i = 0.U64
		while $i < items.len() {
			k = Scm.arg(items, $i)
			key = Scm.symbol(k, "a keyword")?
			if !key.starts_with(":") {
				return Err(Scm.bad(k, "expected a :keyword, got ${key}"))
			}
			if $out.any(|f| f.key == key) {
				return Err(Scm.bad(k, "${key} is given twice"))
			}
			$out = $out.append({ key, value: Scm.arg(items, $i + 1) })
			$i = $i + 2
		}
		Ok($out)
	}

	required : Sx, List({ key : Str, value : Sx }), Str -> Try(Sx, Problem)
	required = |form, fields, key|
		match fields.find_first(|f| f.key == key) {
			Ok(f) => Ok(f.value)
			Err(_) => Err(Scm.bad(form, "missing ${key}"))
		}

	header_list : Sx -> Try(List(Header), Problem)
	header_list = |sx| {
		items = match sx {
			List(xs, _) => xs
			_ => return Err(Scm.bad(sx, ":headers is a list of (\"name\" \"value\") pairs"))
		}
		var $out = []
		for item in items {
			match item {
				List([Str(name, _), Str(value, _)], _) if name != "" => {
					$out = $out.append({ name, value })
				}
				_ => return Err(Scm.bad(item, "a header is (\"name\" \"value\") with a non-empty name"))
			}
		}
		Ok($out)
	}

	step_form : Sx -> Try(Step, Problem)
	step_form = |form| {
		(head, args, pos) = Scm.split_form(form)?
		one = |n| Scm.arity(form, args, n)
		loc1 = || Scm.locator(Scm.arg(one(1)?, 0))
		loc_text = || {
			a = one(2)?
			Ok((Scm.locator(Scm.arg(a, 0))?, Scm.string(Scm.arg(a, 1), "the text")?))
		}
		loc_bool = || {
			a = one(2)?
			Ok((Scm.locator(Scm.arg(a, 0))?, Scm.boolean(Scm.arg(a, 1), "the expected value")?))
		}
		text1 = |what| Scm.string(Scm.arg(one(1)?, 0), what)
		count1 = |what| Scm.unsigned(Scm.arg(one(1)?, 0), what)
		metric = || {
			a = one(2)?
			name_sx = Scm.arg(a, 0)
			name = Scm.symbol(name_sx, "the metric")?
			_ = Scm.metric_counters(name) ? |_| Scm.bad(name_sx, Scm.unknown_metric(name))
			Ok({ metric: name, delta: Scm.integer(Scm.arg(a, 1), "the delta")? })
		}
		op = match head {
			"click" => Click(loc1()?)
			"real-click" => RealClick(loc1()?)
			"pointer-down" => PointerDown(loc1()?)
			"pointer-up" => PointerUp(loc1()?)
			"pointer-enter" => PointerEnter(loc1()?)
			"pointer-leave" => PointerLeave(loc1()?)
			"focus" => Focus(loc1()?)
			"blur" => Blur(loc1()?)
			"composition-start" => CompositionStart(loc1()?)
			"composition-end" => CompositionEnd(loc1()?)
			"submit" => Submit(loc1()?)
			"check" => Check(loc1()?)
			"uncheck" => Uncheck(loc1()?)
			"expect-visible" => ExpectVisible(loc1()?)
			"expect-absent" => ExpectAbsent(loc1()?)
			"fill" => {
				(l, t) = loc_text()?
				Fill(l, t)
			}
			"change" => {
				(l, t) = loc_text()?
				Change(l, t)
			}
			"select-option" => {
				(l, t) = loc_text()?
				SelectOption(l, t)
			}
			"expect-text" => {
				(l, t) = loc_text()?
				ExpectText(l, t)
			}
			"expect-value" => {
				(l, t) = loc_text()?
				ExpectValue(l, t)
			}
			"expect-checked" => {
				(l, b) = loc_bool()?
				ExpectChecked(l, b)
			}
			"expect-disabled" => {
				(l, b) = loc_bool()?
				ExpectDisabled(l, b)
			}
			"expect-updates" => {
				a = one(2)?
				ExpectUpdates(Scm.locator(Scm.arg(a, 0))?, Scm.unsigned(Scm.arg(a, 1), "the update count")?)
			}
			"key-down" => {
				a = one(3)?
				KeyDown({ target: Scm.locator(Scm.arg(a, 0))?, key: Scm.string(Scm.arg(a, 1), "the key")?, shift: Scm.boolean(Scm.arg(a, 2), "shift")? })
			}
			"custom-event" => {
				a = one(3)?
				CustomEvent({ target: Scm.locator(Scm.arg(a, 0))?, name: Scm.string(Scm.arg(a, 1), "the event name")?, detail: Scm.string(Scm.arg(a, 2), "the detail")? })
			}
			"expect-attr" => {
				a = one(3)?
				ExpectAttr({ target: Scm.locator(Scm.arg(a, 0))?, name: Scm.attr_name(Scm.arg(a, 1))?, value: Scm.string(Scm.arg(a, 2), "the attribute value")? })
			}
			"expect-no-attr" => {
				a = one(2)?
				ExpectNoAttr({ target: Scm.locator(Scm.arg(a, 0))?, name: Scm.attr_name(Scm.arg(a, 1))? })
			}
			"stub-http" => StubHttp(Scm.http_fixture(form, head, args)?)
			"stub-http-reject" => StubHttp(Scm.http_fixture(form, head, args)?)
			"run-effect" => RunEffect(count1("the effect occurrence")?)
			"expect-pending-effects" => ExpectPendingEffects(count1("the pending count")?)
			"tick-interval" => TickInterval(count1("the period")?)
			"tick-interval-if-active" => TickIntervalIfActive(count1("the period")?)
			"expect-cleanup" => {
				a = one(2)?
				ExpectCleanup({ name: Scm.string(Scm.arg(a, 0), "the cleanup name")?, count: Scm.unsigned(Scm.arg(a, 1), "the count")? })
			}
			"expect-interval" => {
				a = one(2)?
				ExpectInterval({ period_ms: Scm.unsigned(Scm.arg(a, 0), "the period")?, count: Scm.unsigned(Scm.arg(a, 1), "the count")? })
			}
			"navigate" => Navigate(Scm.location(Scm.arg(one(1)?, 0))?)
			"set-visibility" => SetVisibility(Scm.visibility(Scm.arg(one(1)?, 0))?)
			"set-online" => SetOnline(Scm.online(Scm.arg(one(1)?, 0))?)
			"history-back" => {
				_ = one(0)?
				HistoryBack
			}
			"history-forward" => {
				_ = one(0)?
				HistoryForward
			}
			"expect-current-location" => ExpectLocation(text1("the location")?)
			"assert-current-location" => ExpectLocation(text1("the location")?)
			"expect-document-title" => ExpectTitle(text1("the title")?)
			"expect-local-storage" => ExpectLocalStorage(Scm.key_value(form, args)?)
			"expect-session-storage" => ExpectSessionStorage(Scm.key_value(form, args)?)
			"expect-no-local-storage" => ExpectNoLocalStorage(text1("the key")?)
			"expect-no-session-storage" => ExpectNoSessionStorage(text1("the key")?)
			"mark-metrics" => {
				_ = one(0)?
				MarkMetrics
			}
			"expect-metric-delta" => ExpectMetricDelta(metric()?)
			"expect-metric-delta-at-most" => ExpectMetricDeltaAtMost(metric()?)
			_ => return Err(Scm.bad(form, "unknown step ${head}"))
		}
		Ok({ op, pos })
	}

	attr_name : Sx -> Try(Str, Problem)
	attr_name = |sx|
		match sx {
			Sym(s, _) => Ok(s)
			Str(s, _) => Ok(s)
			_ => Err(Scm.bad(sx, "an attribute name is a bare word or a string"))
		}

	# --------------------------------------------------------------- metrics

	## The work metrics a spec may name (design.md, "Work assertions"), and
	## the engine work counters each one sums. Counter `k` is the `k`th entry
	## of the engine's work record (design.md, Appendix B): 1-18 count
	## commands by opcode, 19 onwards count engine work.
	metric_names : List({ name : Str, counters : List(U64) })
	metric_names = [
		{ name: "rows_created", counters: [1] },
		{ name: "rows_removed", counters: [22] },
		{ name: "rows_reused", counters: [23] },
		{ name: "rows_moved", counters: [4] },
		{ name: "create_element", counters: [8] },
		{ name: "set_text", counters: [2, 12] },
		{ name: "set_value", counters: [19] },
		{ name: "set_checked", counters: [20] },
		{ name: "bind_event", counters: [11] },
		{ name: "set_metadata", counters: [17] },
		{ name: "patches_emitted", counters: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] },
		{ name: "derived_calls_into_roc", counters: [21] },
		{ name: "scopes_created", counters: [25] },
		{ name: "scopes_disposed", counters: [26] },
		{ name: "dirty_source_roots", counters: [27] },
		{ name: "each_key_hashes", counters: [28] },
		{ name: "each_key_compares", counters: [29] },
	]

	## The counters a metric name sums.
	metric_counters : Str -> Try(List(U64), [UnknownMetric])
	metric_counters = |name|
		match Scm.metric_names.find_first(|m| m.name == name) {
			Ok(m) => Ok(m.counters)
			Err(_) => Err(UnknownMetric)
		}

	## Metrics of the deleted Zig engine with no meaning in this one
	## (design.md, "Work assertions"): a spec asserts the property they stood
	## for through soak plateaus or the counters above instead.
	unknown_metric : Str -> Str
	unknown_metric = |name| "unknown metric ${name}; the metrics are ${Str.join_with(Scm.metric_names.map(|m| m.name), ", ")}"

	# ------------------------------------------------------------ properties

	## The step's name as a spec spells it (aliases spell their canonical name).
	op_name : Op -> Str
	op_name = |op|
		match op {
			Click(_) => "click"
			RealClick(_) => "real-click"
			PointerDown(_) => "pointer-down"
			PointerUp(_) => "pointer-up"
			PointerEnter(_) => "pointer-enter"
			PointerLeave(_) => "pointer-leave"
			KeyDown(_) => "key-down"
			Focus(_) => "focus"
			Blur(_) => "blur"
			Change(_, _) => "change"
			SelectOption(_, _) => "select-option"
			CompositionStart(_) => "composition-start"
			CompositionEnd(_) => "composition-end"
			CustomEvent(_) => "custom-event"
			Submit(_) => "submit"
			Fill(_, _) => "fill"
			Check(_) => "check"
			Uncheck(_) => "uncheck"
			ExpectText(_, _) => "expect-text"
			ExpectVisible(_) => "expect-visible"
			ExpectAbsent(_) => "expect-absent"
			ExpectValue(_, _) => "expect-value"
			ExpectAttr(_) => "expect-attr"
			ExpectNoAttr(_) => "expect-no-attr"
			ExpectChecked(_, _) => "expect-checked"
			ExpectDisabled(_, _) => "expect-disabled"
			ExpectUpdates(_, _) => "expect-updates"
			StubHttp({ stub: Reply(_), .. }) => "stub-http"
			StubHttp({ stub: Reject(_), .. }) => "stub-http-reject"
			RunEffect(_) => "run-effect"
			ExpectPendingEffects(_) => "expect-pending-effects"
			TickInterval(_) => "tick-interval"
			TickIntervalIfActive(_) => "tick-interval-if-active"
			ExpectCleanup(_) => "expect-cleanup"
			ExpectInterval(_) => "expect-interval"
			Navigate(_) => "navigate"
			SetVisibility(_) => "set-visibility"
			SetOnline(_) => "set-online"
			HistoryBack => "history-back"
			HistoryForward => "history-forward"
			ExpectLocation(_) => "expect-current-location"
			ExpectTitle(_) => "expect-document-title"
			ExpectLocalStorage(_) => "expect-local-storage"
			ExpectSessionStorage(_) => "expect-session-storage"
			ExpectNoLocalStorage(_) => "expect-no-local-storage"
			ExpectNoSessionStorage(_) => "expect-no-session-storage"
			MarkMetrics => "mark-metrics"
			ExpectMetricDelta(_) => "expect-metric-delta"
			ExpectMetricDeltaAtMost(_) => "expect-metric-delta-at-most"
		}

	## A locator as a spec spells it.
	show_loc : Loc -> Str
	show_loc = |loc|
		match loc {
			Role({ role, name }) => "(role ${role} :name ${JsonOut.quote(name)})"
			Label(x) => "(label ${JsonOut.quote(x)})"
			Text(x) => "(text ${JsonOut.quote(x)})"
			TestId(x) => "(test-id ${JsonOut.quote(x)})"
		}

	# ------------------------------------------------------------------ JSON

	## The spec as one JSON object, for the browser runner:
	## `{"id", "name", "setup": [...], "steps": [...]}`. Each step carries
	## `op` (its spec spelling), `line`, `column`, and its arguments under
	## fixed names (`loc`, `text`, `value`, `count`, ...).
	to_json : Str, Spec -> JsonOut.Value
	to_json = |id, spec|
		Object([
			JsonOut.field("id", Text(id)),
			JsonOut.field("name", Text(spec.name)),
			JsonOut.field("setup", Array(spec.setup.map(|s| Scm.setup_json(s)))),
			JsonOut.field("steps", Array(spec.steps.map(|s| Scm.step_json(s)))),
		])

	loc_json : Loc -> JsonOut.Value
	loc_json = |loc|
		match loc {
			Role({ role, name }) => Object([JsonOut.field("kind", Text("role")), JsonOut.field("role", Text(role)), JsonOut.field("name", Text(name))])
			Label(x) => Object([JsonOut.field("kind", Text("label")), JsonOut.field("value", Text(x))])
			Text(x) => Object([JsonOut.field("kind", Text("text")), JsonOut.field("value", Text(x))])
			TestId(x) => Object([JsonOut.field("kind", Text("test-id")), JsonOut.field("value", Text(x))])
		}

	stub_fields : { label : Str, stub : Stub } -> List({ key : Str, value : JsonOut.Value })
	stub_fields = |{ label, stub }|
		match stub {
			Reply({ url, status, headers, body }) => [
				JsonOut.field("label", Text(label)),
				JsonOut.field("url", Text(url)),
				JsonOut.field("status", Nat(status.to_u64())),
				JsonOut.field("headers", Array(headers.map(|h| Array([Text(h.name), Text(h.value)])))),
				JsonOut.field("body", Text(body)),
			]
			Reject({ kind, detail }) => [
				JsonOut.field("label", Text(label)),
				JsonOut.field("kind", Text(Scm.reject_kind_name(kind))),
				JsonOut.field("detail", Text(detail)),
			]
		}

	reject_kind_name : RejectKind -> Str
	reject_kind_name = |kind|
		match kind {
			Network => "network"
			Timeout => "timeout"
		}

	visibility_name : Visibility -> Str
	visibility_name = |v| if (v == Visible) "visible" else "hidden"

	online_name : Online -> Str
	online_name = |o| if (o == Online) "online" else "offline"

	pos_fields : Pos -> List({ key : Str, value : JsonOut.Value })
	pos_fields = |pos| [JsonOut.field("line", Nat(pos.line)), JsonOut.field("column", Nat(pos.column))]

	setup_json : { item : Setup, pos : Pos } -> JsonOut.Value
	setup_json = |{ item, pos }| {
		(op, args) = match item {
			ManualEffects => ("manual-effects", [])
			InitialLocation(url) => ("initial-location", [JsonOut.field("text", Text(url))])
			InitialVisibility(v) => ("initial-visibility", [JsonOut.field("text", Text(Scm.visibility_name(v)))])
			InitialOnline(o) => ("initial-online", [JsonOut.field("text", Text(Scm.online_name(o)))])
			LocalStorage({ key, value }) => ("local-storage", [JsonOut.field("key", Text(key)), JsonOut.field("text", Text(value))])
			LocalStorageUnavailable => ("local-storage-unavailable", [])
			SessionStorage({ key, value }) => ("session-storage", [JsonOut.field("key", Text(key)), JsonOut.field("text", Text(value))])
			SeedHttp(fixture) => (if (Scm.is_reject(fixture.stub)) "stub-http-reject" else "stub-http", Scm.stub_fields(fixture))
		}
		Object([JsonOut.field("op", Text(op))].concat(Scm.pos_fields(pos)).concat(args))
	}

	is_reject : Stub -> Bool
	is_reject = |stub|
		match stub {
			Reject(_) => Bool.True
			Reply(_) => Bool.False
		}

	counters_json : Str -> JsonOut.Value
	counters_json = |metric| Array((Scm.metric_counters(metric) ?? []).map(|k| Nat(k)))

	step_json : Step -> JsonOut.Value
	step_json = |{ op, pos }| {
		loc = |l| JsonOut.field("loc", Scm.loc_json(l))
		text = |t| JsonOut.field("text", Text(t))
		args = match op {
			Click(l) => [loc(l)]
			RealClick(l) => [loc(l)]
			PointerDown(l) => [loc(l)]
			PointerUp(l) => [loc(l)]
			PointerEnter(l) => [loc(l)]
			PointerLeave(l) => [loc(l)]
			KeyDown({ target, key, shift }) => [loc(target), JsonOut.field("key", Text(key)), JsonOut.field("shift", Bool(shift))]
			Focus(l) => [loc(l)]
			Blur(l) => [loc(l)]
			Change(l, t) => [loc(l), text(t)]
			SelectOption(l, t) => [loc(l), text(t)]
			CompositionStart(l) => [loc(l)]
			CompositionEnd(l) => [loc(l)]
			CustomEvent({ target, name, detail }) => [loc(target), JsonOut.field("name", Text(name)), JsonOut.field("detail", Text(detail))]
			Submit(l) => [loc(l)]
			Fill(l, t) => [loc(l), text(t)]
			Check(l) => [loc(l)]
			Uncheck(l) => [loc(l)]
			ExpectText(l, t) => [loc(l), text(t)]
			ExpectVisible(l) => [loc(l)]
			ExpectAbsent(l) => [loc(l)]
			ExpectValue(l, t) => [loc(l), text(t)]
			ExpectAttr({ target, name, value }) => [loc(target), JsonOut.field("name", Text(name)), text(value)]
			ExpectNoAttr({ target, name }) => [loc(target), JsonOut.field("name", Text(name))]
			ExpectChecked(l, b) => [loc(l), JsonOut.field("value", Bool(b))]
			ExpectDisabled(l, b) => [loc(l), JsonOut.field("value", Bool(b))]
			ExpectUpdates(l, n) => [loc(l), JsonOut.field("count", Nat(n))]
			StubHttp(fixture) => Scm.stub_fields(fixture)
			RunEffect(n) => [JsonOut.field("count", Nat(n))]
			ExpectPendingEffects(n) => [JsonOut.field("count", Nat(n))]
			TickInterval(ms) => [JsonOut.field("period_ms", Nat(ms))]
			TickIntervalIfActive(ms) => [JsonOut.field("period_ms", Nat(ms))]
			ExpectCleanup({ name, count }) => [JsonOut.field("name", Text(name)), JsonOut.field("count", Nat(count))]
			ExpectInterval({ period_ms, count }) => [JsonOut.field("period_ms", Nat(period_ms)), JsonOut.field("count", Nat(count))]
			Navigate(url) => [text(url)]
			SetVisibility(v) => [text(Scm.visibility_name(v))]
			SetOnline(o) => [text(Scm.online_name(o))]
			HistoryBack => []
			HistoryForward => []
			ExpectLocation(url) => [text(url)]
			ExpectTitle(t) => [text(t)]
			ExpectLocalStorage({ key, value }) => [JsonOut.field("key", Text(key)), text(value)]
			ExpectSessionStorage({ key, value }) => [JsonOut.field("key", Text(key)), text(value)]
			ExpectNoLocalStorage(key) => [JsonOut.field("key", Text(key))]
			ExpectNoSessionStorage(key) => [JsonOut.field("key", Text(key))]
			MarkMetrics => []
			ExpectMetricDelta({ metric, delta }) => [JsonOut.field("metric", Text(metric)), JsonOut.field("counters", Scm.counters_json(metric)), JsonOut.field("delta", Int(delta))]
			ExpectMetricDeltaAtMost({ metric, delta }) => [JsonOut.field("metric", Text(metric)), JsonOut.field("counters", Scm.counters_json(metric)), JsonOut.field("delta", Int(delta))]
		}
		Object([JsonOut.field("op", Text(Scm.op_name(op)))].concat(Scm.pos_fields(pos)).concat(args))
	}
}

## Parse failures report the message and the position of the offending form.
problem_of : Str -> Str
problem_of = |text|
	match Scm.parse(text) {
		Ok(_) => "parsed"
		Err(p) => Scm.show_problem("x.scm", p)
	}

## Setup, steps, locators and comments decode, with each step's position.
expect {
	text =
		\\(test "save a profile"
		\\  ; setup is applied before mount
		\\  (setup
		\\    (initial-location "/profile")
		\\    (initial-online offline)
		\\    (local-storage "draft" "saved"))
		\\  (steps
		\\    (fill (label "Email") "a@example.com")
		\\    (real-click (role button :name "Save"))
		\\    (expect-text (test-id "status") "Saved")
		\\    (expect-metric-delta rows_reused 2)))
	spec = Scm.parse(text)?
	actual =
		\\name: ${spec.name}
		\\setup: ${Str.inspect(spec.setup.map(|s| s.item))}
		\\steps: ${Str.inspect(spec.steps.map(|s| s.op))}
		\\first step at: ${Str.inspect(spec.steps.map(|s| s.pos).first()?)}
	expected =
		\\name: save a profile
		\\setup: [InitialLocation("/profile"), InitialOnline(Offline), LocalStorage({ key: "draft", value: "saved" })]
		\\steps: [Fill(Label("Email"), "a@example.com"), RealClick(Role({ name: "Save", role: "button" })), ExpectText(TestId("status"), "Saved"), ExpectMetricDelta({ delta: 2, metric: "rows_reused" })]
		\\first step at: { column: 5, line: 8 }
	actual == expected
}

## `local-storage-unavailable` takes no arguments.
expect {
	spec = Scm.parse("(test \"s\" (setup (local-storage-unavailable)) (steps (expect-visible (text \"x\"))))")?
	bad = Scm.parse("(test \"s\" (setup (local-storage-unavailable \"k\")) (steps (expect-visible (text \"x\"))))")
	spec.setup.map(|s| s.item) == [LocalStorageUnavailable] and bad.is_err()
}

## Escapes decode, and quotes and backslashes may appear in names.
expect {
	spec = Scm.parse("(test \"q\" (steps (click (label \"Go to C:\\\\Users\")) (expect-text (role button :name \"say \\\"hi\\\"\") \"a\\tb\")))")?
	spec.steps.map(|s| s.op) == [Click(Label("Go to C:\\Users")), ExpectText(Role({ role: "button", name: "say \"hi\"" }), "a\tb")]
}

## HTTP stubs keep url, status, headers and body; rejects carry a typed kind.
expect {
	spec = Scm.parse(
		\\(test "http"
		\\  (setup (manual-effects))
		\\  (steps
		\\    (stub-http "feed" :url "/api/a" :status 200 :headers (("content-type" "text/plain")) :body "hi λ")
		\\    (stub-http-reject "x" :kind timeout :detail "")
		\\    (run-effect 2)
		\\    (expect-pending-effects 0)))
	)?
	Str.inspect(spec.steps.map(|s| s.op)) == "[StubHttp({ label: \"feed\", stub: Reply({ body: \"hi λ\", headers: [{ name: \"content-type\", value: \"text/plain\" }], status: 200, url: \"/api/a\" }) }), StubHttp({ label: \"x\", stub: Reject({ detail: \"\", kind: Timeout }) }), RunEffect(2), ExpectPendingEffects(0)]"
}

## An unknown step is a hard error naming its line and column.
expect problem_of("(test \"t\"\n  (steps\n    (click (label \"a\"))\n    (frobnicate 1)))") == "x.scm:4:5: unknown step frobnicate"

## Setup vocabulary is not a step, and steps are not setup.
expect problem_of("(test \"t\" (steps (manual-effects)))") == "x.scm:1:18: unknown step manual-effects"

## Executable steps are refused inside setup.
expect problem_of("(test \"t\" (setup (click (text \"No\"))) (steps (mark-metrics)))") == "x.scm:1:18: unknown setup form click"

## The GUI scenario form is not part of the web grammar.
expect problem_of("(scenario \"s\" (steps (click (text \"a\"))))") == "x.scm:1:2: a spec starts with `test`; `scenario` and other forms are not part of the web grammar"

## Empty steps, missing steps and duplicated sections are refused.
expect {
	actual =
		\\${problem_of("(test \"t\" (steps))")}
		\\${problem_of("(test \"t\" (setup))")}
		\\${problem_of("(test \"t\" (steps (mark-metrics)) (steps (mark-metrics)))")}
		\\${problem_of("(test \"t\" (steps (mark-metrics)) (setup))")}
	expected =
		\\x.scm:1:11: steps must hold at least one step
		\\x.scm:1:1: the test has no (steps ...) section
		\\x.scm:1:34: steps must come once
		\\x.scm:1:34: setup must come once, before steps
	actual == expected
}

## Malformed s-expressions report where they go wrong.
expect {
	actual =
		\\${problem_of("(test \"t\" (steps (click (label \"a\")))")}
		\\${problem_of("(test \"t\" (steps (click (label \"a\"))))) extra")}
		\\${problem_of("(test \"unterminated)")}
		\\${problem_of("(test \"t\" (steps (click (label \"a\\q\"))))")}
		\\${problem_of("")}
	expected =
		\\x.scm:1:1: unterminated list
		\\x.scm:1:39: expected exactly one top-level s-expression
		\\x.scm:1:7: unterminated string
		\\x.scm:1:34: unsupported string escape
		\\x.scm:1:1: expected one s-expression
	actual == expected
}

## Arguments are checked: arity, kinds, signs and locator shapes.
expect {
	actual =
		\\${problem_of("(test \"t\" (steps (run-effect -1)))")}
		\\${problem_of("(test \"t\" (steps (run-effect 1 2)))")}
		\\${problem_of("(test \"t\" (steps (expect-checked (label \"a\") yes)))")}
		\\${problem_of("(test \"t\" (steps (click (role button \"Save\"))))")}
		\\${problem_of("(test \"t\" (steps (click (css \".x\"))))")}
		\\${problem_of("(test \"t\" (steps (stub-http-reject \"f\" :kind invented :detail \"x\")))")}
		\\${problem_of("(test \"t\" (steps (stub-http \"f\" :url \"/a\" :status 42 :body \"\")))")}
		\\${problem_of("(test \"t\" (steps (navigate \"nope\")))")}
	expected =
		\\x.scm:1:30: the effect occurrence must be a non-negative integer, got -1
		\\x.scm:1:18: run-effect takes 1 argument(s), got 2
		\\x.scm:1:46: the expected value must be true or false, got yes
		\\x.scm:1:25: a role locator is (role ROLE :name "NAME")
		\\x.scm:1:25: unknown locator kind css; expected role, label, text or test-id
		\\x.scm:1:46: unknown reject kind invented; a request fails with network or timeout
		\\x.scm:1:51: :status must be 100 to 999
		\\x.scm:1:28: a location starts with /, got "nope"
	actual == expected
}

## The emitted JSON names the op, its position and its arguments.
expect {
	spec = Scm.parse("(test \"j\" (setup (local-storage \"k\" \"v\")) (steps (expect-checked (role checkbox :name \"A\") true)))")?
	actual = JsonOut.render(Scm.to_json("j-file", spec))
	actual == "{\"id\":\"j-file\",\"name\":\"j\",\"setup\":[{\"op\":\"local-storage\",\"line\":1,\"column\":18,\"key\":\"k\",\"text\":\"v\"}],\"steps\":[{\"op\":\"expect-checked\",\"line\":1,\"column\":50,\"loc\":{\"kind\":\"role\",\"role\":\"checkbox\",\"name\":\"A\"},\"value\":true}]}"
}

## Metric names are checked: an old engine-only metric is a parse error, and a
## known one emits the counters it sums.
expect {
	spec = Scm.parse("(test \"m\" (steps (mark-metrics) (expect-metric-delta set_text 2)))")?
	actual =
		\\${problem_of("(test \"t\" (steps (expect-metric-delta-at-most active_graph_records_rebuilt 0)))")}
		\\${JsonOut.render(Scm.to_json("m", spec))}
	expected =
		\\x.scm:1:47: unknown metric active_graph_records_rebuilt; the metrics are rows_created, rows_removed, rows_reused, rows_moved, create_element, set_text, set_value, set_checked, bind_event, set_metadata, patches_emitted, derived_calls_into_roc, scopes_created, scopes_disposed, dirty_source_roots, each_key_hashes, each_key_compares
		\\{"id":"m","name":"m","setup":[],"steps":[{"op":"mark-metrics","line":1,"column":18},{"op":"expect-metric-delta","line":1,"column":33,"metric":"set_text","counters":[2,12],"delta":2}]}
	actual == expected
}
