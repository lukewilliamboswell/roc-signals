import JsonOut
import Core

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

	## Why a worker job was lost: the fault class of the instance that ran it
	## (`contract`, `resource_limit`, `out_of_memory`, `app_crash`,
	## `expect_failed`), no Web Worker support (`unavailable`), or the worker
	## script failing (`executor`), as `Engine.WorkFault` has them (design.md,
	## Appendix B, result tag 11). Spelled as design.md and the runtime spell
	## the classes.
	WorkFault : [Contract, ResourceLimit, OutOfMemory, AppCrash, ExpectFailed, Unavailable, Executor]

	## Declarative state applied before the app mounts.
	Setup : [
		InitialLocation(Str),
		InitialVisibility(Visibility),
		InitialOnline(Online),
		LocalStorage({ key : Str, value : Str }),

		## Local storage cannot be used at all: every access throws, as in a
		## browser with site data disabled.
		LocalStorageUnavailable,

		## A file the spec's file steps can give the app: its name, its media
		## type, and its contents, `text` repeated `repeat` times.
		File({ name : Str, mime : Str, text : Str, repeat : U64 }),

		## The most bytes a task's job may append to its builders, the
		## runtime's `maxOutputBytes` mount option (256 MiB when a spec does
		## not say).
		MaxOutputBytes(U64),
	]

	## The browser facts a spec starts from. Boot owns their fixed defaults, so
	## empty boot bytes, a pure Boot literal and a spec agree on every value.
	Environment : Core.Boot

	## Resolve the environment forms once, retaining the source position of a
	## cross-form error. Fixtures and deployment limits do not set browser facts.
	environment : List({ item : Setup, pos : Pos }) -> Try(Environment, Problem)
	environment = |setup| {
		initial : Environment
		initial = {}
		var $env = initial
		for { item, pos } in setup {
			env = $env
			$env = match item {
				InitialLocation(url) => { ..env, url }
				InitialOnline(value) => { ..env, online: value == Online }
				InitialVisibility(value) => { ..env, visible: value == Visible }
				LocalStorage({ key, value }) => {
					if !env.storage_available {
						return Err({ pos, message: "local-storage seeds storage that local-storage-unavailable says the app cannot read" })
					}
					{ ..env, storage: env.storage.keep_if(|(name, _)| name != key).append((key, value)) }
				}
				LocalStorageUnavailable => {
					if !env.storage.is_empty() {
						return Err({ pos, message: "local-storage seeds storage that local-storage-unavailable says the app cannot read" })
					}
					{ ..env, storage_available: Bool.False }
				}
				File(_) | MaxOutputBytes(_) => env
			}
		}
		Ok($env)
	}

	## Facts that survive a new document unchanged. Features with a per-document
	## value extend this hook instead of giving either runner its own reset rule.
	next_document : Environment -> Environment
	next_document = |env| env

	## Every environment section by its wire-table name. The browser replay's
	## appliers must cover exactly this list, checked with the rest of its grammar.
	environment_sections : List(Str)
	environment_sections = ["location", "local-storage", "connectivity", "visibility"]

	## A step a test takes, in order. Both runners implement every step
	## (design.md, "The `.scm` spec language"): the native runner's `one` matches
	## every variant, and the browser runner's handler table is checked against
	## `step_forms` by `replay.mjs --check-grammar`.
	##
	## A metric step names one of `metric_names` (design.md's work-assertion
	## table); any other name is a parse error.
	Op : [
		Click(Loc),
		RealClick(Loc),
		Focus(Loc),
		Blur(Loc),
		Change(Loc, Str),
		SelectOption(Loc, Str),
		Submit(Loc),
		Fill(Loc, Str),
		Check(Loc),
		Uncheck(Loc),
		ExpectText(Loc, Str),
		ExpectVisible(Loc),
		ExpectFocused(Loc),
		ExpectNoFocus,
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

		## Answer the N-th effect occurrence, a pending worker job, as lost
		## with a fault class, without running it.
		LoseWork({ occurrence : U64, fault : WorkFault }),

		## Expire the timeout of the N-th effect occurrence, a pending worker
		## job with a timeout: it is answered `Timeout`.
		TimeOutWork(U64),

		## Exactly `count` worker jobs of the task named `task` are pending.
		ExpectPendingWork({ task : Str, count : U64 }),

		## The user chooses the named setup files in a file input.
		ChooseFiles(Loc, List(Str)),

		## The user drops the named setup files on an element.
		DropFiles(Loc, List(Str)),

		## The user pastes the named setup files into an element.
		PasteFiles(Loc, List(Str)),

		## Exactly `count` file handles are live in the app's instance.
		ExpectFiles(U64),
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
		ExpectNoLocalStorage(Str),
		MarkMetrics,
		ExpectMetricDelta({ metric : Str, delta : I64 }),
		ExpectMetricDeltaAtMost({ metric : Str, delta : I64 }),

		## The N-th effect occurrence is a pending upload whose body is `len`
		## bytes from `start` of the setup file `file`.
		ExpectUpload({ occurrence : U64, file : Str, start : U64, len : U64 }),

		## The N-th effect occurrence is a pending call on `port` whose
		## message is exactly `json`.
		ExpectPortCall({ occurrence : U64, port : Str, json : Str }),

		## Answer the N-th effect occurrence, a pending port call.
		AnswerPort({ occurrence : U64, answer : PortAnswer }),

		## The `index`-th command (from 1) sent on `port` in this document
		## carried exactly `json`.
		ExpectPortSent({ port : Str, index : U64, json : Str }),

		## Exactly `count` commands were sent on `port` in this document.
		ExpectPortSends({ port : Str, count : U64 }),

		## Deliver `json` to every live subscription on `port`; a step with
		## none live fails.
		EmitPort({ port : Str, json : Str }),

		## The JavaScript ends every live subscription on `port` (`Closed`).
		ClosePort(Str),

		## The JavaScript fails every live subscription on `port` with a
		## message (`Threw`), which ends it.
		FailPort({ port : Str, message : Str }),

		## Exactly `count` subscriptions on `port` are live.
		ExpectPortSubscriptions({ port : Str, count : U64 }),

		## The `index`-th file (from 1) the app saved in this document
		## (`File.save`) was named `name` and held exactly `text`.
		ExpectSaved({ index : U64, name : Str, text : Str }),

		## Exactly `count` files were saved in this document.
		ExpectSaves(U64),
	]

	## How a spec answers a pending port call: JSON text (delivered as it is
	## written, so a spec can answer what the app's type does not accept), a
	## throw with its message, an answer too large, or its timeout expiring.
	PortAnswer : [Reply(Str), Throw(Str), TooLarge, Timeout]

	## A step with the position of its form.
	Step : { op : Op, pos : Pos }

	## A parsed spec file and its resolved browser facts. The defaulted field
	## also lets a pure harness construct a spec with Boot's default environment.
	Spec := { name : Str, setup : List({ item : Setup, pos : Pos }), steps : List(Step), environment : Environment ?? {} }.{
		is_eq : _
	}

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
			return Err({ pos: Scm.pos_of(head), message: "a spec starts with `test`" })
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
		Ok({ name, setup: $setup, steps: $steps, environment: Scm.environment($setup)? })
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

	## Every setup form, by its spelling, with its argument parser. The parser
	## accepts exactly these; anything else is an unknown setup form.
	setup_forms : List({ name : Str, parse : (Sx, List(Sx) -> Try(Setup, Problem)) })
	setup_forms = [
		{ name: "initial-location", parse: |form, args| Ok(InitialLocation(Scm.location(Scm.arg(Scm.arity(form, args, 1)?, 0))?)) },
		{ name: "initial-visibility", parse: |form, args| Ok(InitialVisibility(Scm.visibility(Scm.arg(Scm.arity(form, args, 1)?, 0))?)) },
		{ name: "initial-online", parse: |form, args| Ok(InitialOnline(Scm.online(Scm.arg(Scm.arity(form, args, 1)?, 0))?)) },
		{ name: "local-storage", parse: |form, args| Ok(LocalStorage(Scm.key_value(form, args)?)) },
		{
			name: "local-storage-unavailable",
			parse: |form, args| {
				_ = Scm.arity(form, args, 0)?
				Ok(LocalStorageUnavailable)
			},
		},
		{
			name: "file",
			parse: |form, args| {
				if args.len() != 3 and args.len() != 4 {
					return Err(Scm.bad(form, "file takes a name, a type, the contents and optionally a repeat count"))
				}
				name_sx = Scm.arg(args, 0)
				name = Scm.string(name_sx, "the file name")?
				if name == "" or name.contains("/") {
					return Err(Scm.bad(name_sx, "a file name must be a non-empty name without a directory"))
				}
				repeat = if (args.len() == 4) Scm.unsigned(Scm.arg(args, 3), "the repeat count")? else 1
				Ok(File({ name, mime: Scm.string(Scm.arg(args, 1), "the media type")?, text: Scm.string(Scm.arg(args, 2), "the contents")?, repeat }))
			},
		},
		{ name: "max-output-bytes", parse: |form, args| Ok(MaxOutputBytes(Scm.unsigned(Scm.arg(Scm.arity(form, args, 1)?, 0), "the byte count")?)) },
	]

	## A locator and one or more setup file names.
	loc_files : Sx, List(Sx) -> Try((Loc, List(Str)), Problem)
	loc_files = |form, args| {
		if args.len() < 2 {
			return Err(Scm.bad(form, "expected a locator and at least one file name"))
		}
		var $names = []
		for sx in args.drop_first(1) {
			$names = $names.append(Scm.string(sx, "a file name")?)
		}
		Ok((Scm.locator(Scm.arg(args, 0))?, $names))
	}

	setup_form : Sx -> Try({ item : Setup, pos : Pos }, Problem)
	setup_form = |form| {
		(head, args, pos) = Scm.split_form(form)?
		entry = Scm.setup_forms.find_first(|f| f.name == head) ? |_| Scm.bad(form, "unknown setup form ${head}")
		item = (entry.parse)(form, args)?
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

	## Every step form, by its spelling, with its argument parser. The parser
	## accepts exactly these; anything else is an unknown step.
	step_forms : List({ name : Str, parse : (Sx, List(Sx) -> Try(Op, Problem)) })
	step_forms = [
		{ name: "click", parse: |form, args| Ok(Click(Scm.loc1(form, args)?)) },
		{ name: "real-click", parse: |form, args| Ok(RealClick(Scm.loc1(form, args)?)) },
		{ name: "focus", parse: |form, args| Ok(Focus(Scm.loc1(form, args)?)) },
		{ name: "blur", parse: |form, args| Ok(Blur(Scm.loc1(form, args)?)) },
		{ name: "submit", parse: |form, args| Ok(Submit(Scm.loc1(form, args)?)) },
		{ name: "check", parse: |form, args| Ok(Check(Scm.loc1(form, args)?)) },
		{ name: "uncheck", parse: |form, args| Ok(Uncheck(Scm.loc1(form, args)?)) },
		{ name: "fill", parse: |form, args| Scm.loc_text(form, args).map_ok(|(l, t)| Fill(l, t)) },
		{ name: "change", parse: |form, args| Scm.loc_text(form, args).map_ok(|(l, t)| Change(l, t)) },
		{ name: "select-option", parse: |form, args| Scm.loc_text(form, args).map_ok(|(l, t)| SelectOption(l, t)) },
		{ name: "expect-text", parse: |form, args| Scm.loc_text(form, args).map_ok(|(l, t)| ExpectText(l, t)) },
		{ name: "expect-focused", parse: |form, args| Ok(ExpectFocused(Scm.loc1(form, args)?)) },
		{
			name: "expect-no-focus",
			parse: |form, args| {
				_ = Scm.arity(form, args, 0)?
				Ok(ExpectNoFocus)
			},
		},
		{ name: "expect-visible", parse: |form, args| Ok(ExpectVisible(Scm.loc1(form, args)?)) },
		{ name: "expect-absent", parse: |form, args| Ok(ExpectAbsent(Scm.loc1(form, args)?)) },
		{ name: "expect-value", parse: |form, args| Scm.loc_text(form, args).map_ok(|(l, t)| ExpectValue(l, t)) },
		{
			name: "expect-attr",
			parse: |form, args| {
				a = Scm.arity(form, args, 3)?
				Ok(ExpectAttr({ target: Scm.locator(Scm.arg(a, 0))?, name: Scm.attr_name(Scm.arg(a, 1))?, value: Scm.string(Scm.arg(a, 2), "the attribute value")? }))
			},
		},
		{
			name: "expect-no-attr",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				name_sx = Scm.arg(a, 1)
				name = Scm.attr_name(name_sx)?
				match name {
					"checked" | "disabled" | "value" => Err(Scm.bad(name_sx, "${name} is live control state, not an attribute; assert it with expect-${name}"))
					_ => Ok(ExpectNoAttr({ target: Scm.locator(Scm.arg(a, 0))?, name }))
				}
			},
		},
		{ name: "expect-checked", parse: |form, args| Scm.loc_bool(form, args).map_ok(|(l, b)| ExpectChecked(l, b)) },
		{ name: "expect-disabled", parse: |form, args| Scm.loc_bool(form, args).map_ok(|(l, b)| ExpectDisabled(l, b)) },
		{
			name: "expect-updates",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				Ok(ExpectUpdates(Scm.locator(Scm.arg(a, 0))?, Scm.unsigned(Scm.arg(a, 1), "the update count")?))
			},
		},
		{ name: "stub-http", parse: |form, args| Ok(StubHttp(Scm.http_fixture(form, "stub-http", args)?)) },
		{ name: "stub-http-reject", parse: |form, args| Ok(StubHttp(Scm.http_fixture(form, "stub-http-reject", args)?)) },
		{ name: "run-effect", parse: |form, args| Ok(RunEffect(Scm.count1(form, args, "the effect occurrence")?)) },
		{ name: "expect-pending-effects", parse: |form, args| Ok(ExpectPendingEffects(Scm.count1(form, args, "the pending count")?)) },
		{
			name: "lose-work",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				Ok(LoseWork({ occurrence: Scm.unsigned(Scm.arg(a, 0), "the effect occurrence")?, fault: Scm.work_fault(Scm.arg(a, 1))? }))
			},
		},
		{ name: "time-out-work", parse: |form, args| Ok(TimeOutWork(Scm.count1(form, args, "the effect occurrence")?)) },
		{ name: "choose-files", parse: |form, args| Scm.loc_files(form, args).map_ok(|(l, names)| ChooseFiles(l, names)) },
		{ name: "drop-files", parse: |form, args| Scm.loc_files(form, args).map_ok(|(l, names)| DropFiles(l, names)) },
		{ name: "paste-files", parse: |form, args| Scm.loc_files(form, args).map_ok(|(l, names)| PasteFiles(l, names)) },
		{ name: "expect-files", parse: |form, args| Ok(ExpectFiles(Scm.unsigned(Scm.arg(Scm.arity(form, args, 1)?, 0), "the file count")?)) },
		{
			name: "expect-pending-work",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				task_sx = Scm.arg(a, 0)
				task = Scm.string(task_sx, "the task name")?
				if task == "" {
					return Err(Scm.bad(task_sx, "the task name must not be empty"))
				}
				Ok(ExpectPendingWork({ task, count: Scm.unsigned(Scm.arg(a, 1), "the pending count")? }))
			},
		},
		{ name: "tick-interval", parse: |form, args| Ok(TickInterval(Scm.count1(form, args, "the period")?)) },
		{ name: "tick-interval-if-active", parse: |form, args| Ok(TickIntervalIfActive(Scm.count1(form, args, "the period")?)) },
		{
			name: "expect-cleanup",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				Ok(ExpectCleanup({ name: Scm.string(Scm.arg(a, 0), "the cleanup name")?, count: Scm.unsigned(Scm.arg(a, 1), "the count")? }))
			},
		},
		{
			name: "expect-interval",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				Ok(ExpectInterval({ period_ms: Scm.unsigned(Scm.arg(a, 0), "the period")?, count: Scm.unsigned(Scm.arg(a, 1), "the count")? }))
			},
		},
		{ name: "navigate", parse: |form, args| Ok(Navigate(Scm.location(Scm.arg(Scm.arity(form, args, 1)?, 0))?)) },
		{ name: "set-visibility", parse: |form, args| Ok(SetVisibility(Scm.visibility(Scm.arg(Scm.arity(form, args, 1)?, 0))?)) },
		{ name: "set-online", parse: |form, args| Ok(SetOnline(Scm.online(Scm.arg(Scm.arity(form, args, 1)?, 0))?)) },
		{ name: "history-back", parse: |form, args| Scm.arity(form, args, 0).map_ok(|_| HistoryBack) },
		{ name: "history-forward", parse: |form, args| Scm.arity(form, args, 0).map_ok(|_| HistoryForward) },
		{ name: "expect-current-location", parse: |form, args| Ok(ExpectLocation(Scm.text1(form, args, "the location")?)) },
		{ name: "expect-document-title", parse: |form, args| Ok(ExpectTitle(Scm.text1(form, args, "the title")?)) },
		{ name: "expect-local-storage", parse: |form, args| Ok(ExpectLocalStorage(Scm.key_value(form, args)?)) },
		{ name: "expect-no-local-storage", parse: |form, args| Ok(ExpectNoLocalStorage(Scm.text1(form, args, "the key")?)) },
		{ name: "mark-metrics", parse: |form, args| Scm.arity(form, args, 0).map_ok(|_| MarkMetrics) },
		{ name: "expect-metric-delta", parse: |form, args| Ok(ExpectMetricDelta(Scm.metric_args(form, args)?)) },
		{ name: "expect-metric-delta-at-most", parse: |form, args| Ok(ExpectMetricDeltaAtMost(Scm.metric_args(form, args)?)) },
		{
			name: "expect-upload",
			parse: |form, args| {
				a = Scm.arity(form, args, 4)?
				file_sx = Scm.arg(a, 1)
				file = Scm.string(file_sx, "the setup file's name")?
				if file == "" {
					return Err(Scm.bad(file_sx, "the setup file's name must not be empty"))
				}
				Ok(ExpectUpload({ occurrence: Scm.unsigned(Scm.arg(a, 0), "the effect occurrence")?, file, start: Scm.unsigned(Scm.arg(a, 2), "the range's start")?, len: Scm.unsigned(Scm.arg(a, 3), "the range's length")? }))
			},
		},
		{
			name: "expect-port-call",
			parse: |form, args| {
				a = Scm.arity(form, args, 3)?
				Ok(ExpectPortCall({ occurrence: Scm.unsigned(Scm.arg(a, 0), "the effect occurrence")?, port: Scm.port_name(Scm.arg(a, 1))?, json: Scm.string(Scm.arg(a, 2), "the message JSON")? }))
			},
		},
		{ name: "answer-port", parse: |form, args| Scm.port_answer(form, args) },
		{
			name: "expect-port-sent",
			parse: |form, args| {
				a = Scm.arity(form, args, 3)?
				Ok(ExpectPortSent({ port: Scm.port_name(Scm.arg(a, 0))?, index: Scm.unsigned(Scm.arg(a, 1), "the command's place")?, json: Scm.string(Scm.arg(a, 2), "the message JSON")? }))
			},
		},
		{
			name: "expect-port-sends",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				Ok(ExpectPortSends({ port: Scm.port_name(Scm.arg(a, 0))?, count: Scm.unsigned(Scm.arg(a, 1), "the count")? }))
			},
		},
		{
			name: "emit-port",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				Ok(EmitPort({ port: Scm.port_name(Scm.arg(a, 0))?, json: Scm.string(Scm.arg(a, 1), "the message JSON")? }))
			},
		},
		{ name: "close-port", parse: |form, args| Ok(ClosePort(Scm.port_name(Scm.arg(Scm.arity(form, args, 1)?, 0))?)) },
		{
			name: "fail-port",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				Ok(FailPort({ port: Scm.port_name(Scm.arg(a, 0))?, message: Scm.string(Scm.arg(a, 1), "the message")? }))
			},
		},
		{
			name: "expect-port-subscriptions",
			parse: |form, args| {
				a = Scm.arity(form, args, 2)?
				Ok(ExpectPortSubscriptions({ port: Scm.port_name(Scm.arg(a, 0))?, count: Scm.unsigned(Scm.arg(a, 1), "the count")? }))
			},
		},
		{
			name: "expect-saved",
			parse: |form, args| {
				a = Scm.arity(form, args, 3)?
				index_sx = Scm.arg(a, 0)
				index = Scm.unsigned(index_sx, "the save's place")?
				if index == 0 {
					return Err(Scm.bad(index_sx, "saves are counted from 1"))
				}
				Ok(ExpectSaved({ index, name: Scm.string(Scm.arg(a, 1), "the saved file's name")?, text: Scm.string(Scm.arg(a, 2), "the saved file's contents")? }))
			},
		},
		{ name: "expect-saves", parse: |form, args| Ok(ExpectSaves(Scm.unsigned(Scm.arg(Scm.arity(form, args, 1)?, 0), "the save count")?)) },
	]

	## A port name: a non-empty string.
	port_name : Sx -> Try(Str, Problem)
	port_name = |sx| {
		name = Scm.string(sx, "the port name")?
		if (name == "") Err(Scm.bad(sx, "the port name must not be empty")) else Ok(name)
	}

	## `(answer-port N reply "json")`, `(answer-port N throw "message")`,
	## `(answer-port N too-large)` or `(answer-port N timeout)`.
	port_answer : Sx, List(Sx) -> Try(Op, Problem)
	port_answer = |form, args| {
		occurrence = Scm.unsigned(args.get(0) ? |_| Scm.bad(form, "answer-port needs the effect occurrence"), "the effect occurrence")?
		kind_sx = args.get(1) ? |_| Scm.bad(form, "answer-port needs how to answer: reply, throw, too-large or timeout")
		answer = match Scm.symbol(kind_sx, "the answer")? {
			"reply" => Reply(Scm.string(Scm.arg(Scm.arity(form, args, 3)?, 2), "the reply JSON")?)
			"throw" => Throw(Scm.string(Scm.arg(Scm.arity(form, args, 3)?, 2), "the thrown message")?)
			"too-large" => Scm.arity(form, args, 2).map_ok(|_| TooLarge)?
			"timeout" => Scm.arity(form, args, 2).map_ok(|_| Timeout)?
			other => return Err(Scm.bad(kind_sx, "unknown answer ${other}; a port call is answered with reply, throw, too-large or timeout"))
		}
		Ok(AnswerPort({ occurrence, answer }))
	}

	step_form : Sx -> Try(Step, Problem)
	step_form = |form| {
		(head, args, pos) = Scm.split_form(form)?
		entry = Scm.step_forms.find_first(|f| f.name == head) ? |_| Scm.bad(form, "unknown step ${head}")
		op = (entry.parse)(form, args)?
		Ok({ op, pos })
	}

	loc1 : Sx, List(Sx) -> Try(Loc, Problem)
	loc1 = |form, args| Scm.locator(Scm.arg(Scm.arity(form, args, 1)?, 0))

	loc_text : Sx, List(Sx) -> Try((Loc, Str), Problem)
	loc_text = |form, args| {
		a = Scm.arity(form, args, 2)?
		Ok((Scm.locator(Scm.arg(a, 0))?, Scm.string(Scm.arg(a, 1), "the text")?))
	}

	loc_bool : Sx, List(Sx) -> Try((Loc, Bool), Problem)
	loc_bool = |form, args| {
		a = Scm.arity(form, args, 2)?
		Ok((Scm.locator(Scm.arg(a, 0))?, Scm.boolean(Scm.arg(a, 1), "the expected value")?))
	}

	text1 : Sx, List(Sx), Str -> Try(Str, Problem)
	text1 = |form, args, what| Scm.string(Scm.arg(Scm.arity(form, args, 1)?, 0), what)

	count1 : Sx, List(Sx), Str -> Try(U64, Problem)
	count1 = |form, args, what| Scm.unsigned(Scm.arg(Scm.arity(form, args, 1)?, 0), what)

	metric_args : Sx, List(Sx) -> Try({ metric : Str, delta : I64 }, Problem)
	metric_args = |form, args| {
		a = Scm.arity(form, args, 2)?
		name_sx = Scm.arg(a, 0)
		name = Scm.symbol(name_sx, "the metric")?
		_ = Scm.metric_counters(name) ? |_| Scm.bad(name_sx, Scm.unknown_metric(name))
		Ok({ metric: name, delta: Scm.integer(Scm.arg(a, 1), "the delta")? })
	}

	## The grammar's form and environment-section names, for the browser
	## replay to check its handlers and appliers cover the parser completely.
	grammar_json : JsonOut.Value
	grammar_json = Object([
		JsonOut.field("steps", Array(Scm.step_forms.map(|f| Text(f.name)))),
		JsonOut.field("setup", Array(Scm.setup_forms.map(|f| Text(f.name)))),
		JsonOut.field("environment_sections", Array(Scm.environment_sections.map(|name| Text(name)))),
	])

	## Every work fault by its spelling.
	work_faults : List((Str, WorkFault))
	work_faults = [("contract", Contract), ("resource_limit", ResourceLimit), ("out_of_memory", OutOfMemory), ("app_crash", AppCrash), ("expect_failed", ExpectFailed), ("unavailable", Unavailable), ("executor", Executor)]

	work_fault : Sx -> Try(WorkFault, Problem)
	work_fault = |sx| {
		name = Scm.symbol(sx, "the work fault")?
		match Scm.work_faults.find_first(|(n, _)| n == name) {
			Ok((_, f)) => Ok(f)
			Err(_) => Err(Scm.bad(sx, "unknown work fault ${name}; a job is lost to ${Str.join_with(Scm.work_faults.map(|(n, _)| n), ", ")}"))
		}
	}

	## A work fault as a spec spells it.
	work_fault_name : WorkFault -> Str
	work_fault_name = |fault| Scm.work_faults.find_first(|(_, f)| f == fault).map_ok(|(n, _)| n) ?? crash "Scm.work_faults names every fault"

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
	## commands by opcode, 19-31 count engine work, and 32-38 are the effect
	## counters. Counter 39, the live ids, is a gauge rather than a count and
	## has no metric name.
	metric_names : List({ name : Str, counters : List(U64) })
	metric_names = [
		{ name: "rows_created", counters: [1] },
		{ name: "rows_removed", counters: [22] },
		{ name: "rows_reused", counters: [23] },
		{ name: "rows_updated", counters: [24] },
		{ name: "rows_moved", counters: [4] },
		{ name: "create_element", counters: [8] },
		{ name: "set_text", counters: [2, 12] },
		{ name: "set_value", counters: [19] },
		{ name: "set_checked", counters: [20] },
		{ name: "bind_event", counters: [11] },
		{ name: "set_metadata", counters: [17] },
		{ name: "patches_emitted", counters: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 41, 42] },
		{ name: "derived_calls_into_roc", counters: [21] },
		{ name: "scopes_created", counters: [25] },
		{ name: "scopes_disposed", counters: [26] },
		{ name: "dirty_source_roots", counters: [27] },
		{ name: "each_key_hashes", counters: [28] },
		{ name: "each_key_compares", counters: [29] },
		{ name: "effects_issued", counters: [32] },
		{ name: "effects_delivered", counters: [33] },
		{ name: "effects_stale", counters: [34] },
		{ name: "effects_refused", counters: [35] },
		{ name: "effects_cancelled", counters: [36] },
		{ name: "effects_reparented", counters: [37] },
		{ name: "effects_skipped", counters: [38] },
	]

	## The counters a metric name sums.
	metric_counters : Str -> Try(List(U64), [UnknownMetric])
	metric_counters = |name|
		match Scm.metric_names.find_first(|m| m.name == name) {
			Ok(m) => Ok(m.counters)
			Err(_) => Err(UnknownMetric)
		}

	## The problem with a metric name that `metric_names` does not hold,
	## which lists the names it does.
	unknown_metric : Str -> Str
	unknown_metric = |name| "unknown metric ${name}; the metrics are ${Str.join_with(Scm.metric_names.map(|m| m.name), ", ")}"

	# ------------------------------------------------------------ properties

	## The step's name as a spec spells it.
	op_name : Op -> Str
	op_name = |op|
		match op {
			Click(_) => "click"
			RealClick(_) => "real-click"
			Focus(_) => "focus"
			Blur(_) => "blur"
			Change(_, _) => "change"
			SelectOption(_, _) => "select-option"
			Submit(_) => "submit"
			Fill(_, _) => "fill"
			Check(_) => "check"
			Uncheck(_) => "uncheck"
			ExpectText(_, _) => "expect-text"
			ExpectVisible(_) => "expect-visible"
			ExpectFocused(_) => "expect-focused"
			ExpectNoFocus => "expect-no-focus"
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
			LoseWork(_) => "lose-work"
			TimeOutWork(_) => "time-out-work"
			ExpectPendingWork(_) => "expect-pending-work"
			ChooseFiles(_, _) => "choose-files"
			DropFiles(_, _) => "drop-files"
			PasteFiles(_, _) => "paste-files"
			ExpectFiles(_) => "expect-files"
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
			ExpectNoLocalStorage(_) => "expect-no-local-storage"
			MarkMetrics => "mark-metrics"
			ExpectMetricDelta(_) => "expect-metric-delta"
			ExpectMetricDeltaAtMost(_) => "expect-metric-delta-at-most"
			ExpectUpload(_) => "expect-upload"
			ExpectPortCall(_) => "expect-port-call"
			AnswerPort(_) => "answer-port"
			ExpectPortSent(_) => "expect-port-sent"
			ExpectPortSends(_) => "expect-port-sends"
			EmitPort(_) => "emit-port"
			ClosePort(_) => "close-port"
			FailPort(_) => "fail-port"
			ExpectPortSubscriptions(_) => "expect-port-subscriptions"
			ExpectSaved(_) => "expect-saved"
			ExpectSaves(_) => "expect-saves"
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
	## `{"id", "name", "setup", "environment", "steps"}`. Environment facts
	## have already been resolved by the parser. Each step carries
	## `op` (its spec spelling), `line`, `column`, and its arguments under
	## fixed names (`loc`, `text`, `value`, `count`, ...).
	to_json : Str, Spec -> JsonOut.Value
	to_json = |id, spec|
		Object([
			JsonOut.field("id", Text(id)),
			JsonOut.field("name", Text(spec.name)),
			JsonOut.field("setup", Array(spec.setup.map(|s| Scm.setup_json(s)))),
			JsonOut.field("environment", Scm.environment_json(spec.environment)),
			JsonOut.field("steps", Array(spec.steps.map(|s| Scm.step_json(s)))),
		])

	## The already-resolved facts, without defaults or setup rules for a runner
	## to interpret. Storage pairs retain Boot's declared data representation.
	environment_json : Environment -> JsonOut.Value
	environment_json = |env| Object([
		JsonOut.field("url", Text(env.url)),
		JsonOut.field("storage", Array(env.storage.map(|(key, value)| Array([Text(key), Text(value)])))),
		JsonOut.field("storage_available", Bool(env.storage_available)),
		JsonOut.field("online", Bool(env.online)),
		JsonOut.field("visible", Bool(env.visible)),
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
			InitialLocation(url) => ("initial-location", [JsonOut.field("text", Text(url))])
			InitialVisibility(v) => ("initial-visibility", [JsonOut.field("text", Text(Scm.visibility_name(v)))])
			InitialOnline(o) => ("initial-online", [JsonOut.field("text", Text(Scm.online_name(o)))])
			LocalStorage({ key, value }) => ("local-storage", [JsonOut.field("key", Text(key)), JsonOut.field("text", Text(value))])
			LocalStorageUnavailable => ("local-storage-unavailable", [])
			File({ name, mime, text, repeat }) => ("file", [JsonOut.field("name", Text(name)), JsonOut.field("type", Text(mime)), JsonOut.field("text", Text(text)), JsonOut.field("count", Nat(repeat))])
			MaxOutputBytes(n) => ("max-output-bytes", [JsonOut.field("count", Nat(n))])
		}
		Object([JsonOut.field("op", Text(op))].concat(Scm.pos_fields(pos)).concat(args))
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
			Focus(l) => [loc(l)]
			Blur(l) => [loc(l)]
			Change(l, t) => [loc(l), text(t)]
			SelectOption(l, t) => [loc(l), text(t)]
			Submit(l) => [loc(l)]
			Fill(l, t) => [loc(l), text(t)]
			Check(l) => [loc(l)]
			Uncheck(l) => [loc(l)]
			ExpectText(l, t) => [loc(l), text(t)]
			ExpectVisible(l) => [loc(l)]
			ExpectFocused(l) => [loc(l)]
			ExpectNoFocus => []
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
			LoseWork({ occurrence, fault }) => [JsonOut.field("count", Nat(occurrence)), JsonOut.field("fault", Text(Scm.work_fault_name(fault)))]
			TimeOutWork(n) => [JsonOut.field("count", Nat(n))]
			ExpectPendingWork({ task, count }) => [JsonOut.field("task", Text(task)), JsonOut.field("count", Nat(count))]
			ChooseFiles(l, names) => [loc(l), JsonOut.field("files", Array(names.map(|n| Text(n))))]
			DropFiles(l, names) => [loc(l), JsonOut.field("files", Array(names.map(|n| Text(n))))]
			PasteFiles(l, names) => [loc(l), JsonOut.field("files", Array(names.map(|n| Text(n))))]
			ExpectFiles(n) => [JsonOut.field("count", Nat(n))]
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
			ExpectNoLocalStorage(key) => [JsonOut.field("key", Text(key))]
			MarkMetrics => []
			ExpectMetricDelta({ metric, delta }) => [JsonOut.field("metric", Text(metric)), JsonOut.field("counters", Scm.counters_json(metric)), JsonOut.field("delta", Int(delta))]
			ExpectMetricDeltaAtMost({ metric, delta }) => [JsonOut.field("metric", Text(metric)), JsonOut.field("counters", Scm.counters_json(metric)), JsonOut.field("delta", Int(delta))]
			ExpectUpload({ occurrence, file, start, len }) => [JsonOut.field("count", Nat(occurrence)), JsonOut.field("file", Text(file)), JsonOut.field("start", Nat(start)), JsonOut.field("len", Nat(len))]
			ExpectPortCall({ occurrence, port, json }) => [JsonOut.field("count", Nat(occurrence)), JsonOut.field("port", Text(port)), JsonOut.field("json", Text(json))]
			AnswerPort({ occurrence, answer }) =>
				[JsonOut.field("count", Nat(occurrence))].concat(
					match answer {
						Reply(json) => [JsonOut.field("answer", Text("reply")), JsonOut.field("json", Text(json))]
						Throw(message) => [JsonOut.field("answer", Text("throw")), text(message)]
						TooLarge => [JsonOut.field("answer", Text("too-large"))]
						Timeout => [JsonOut.field("answer", Text("timeout"))]
					},
				)
			ExpectPortSent({ port, index, json }) => [JsonOut.field("port", Text(port)), JsonOut.field("index", Nat(index)), JsonOut.field("json", Text(json))]
			ExpectPortSends({ port, count }) => [JsonOut.field("port", Text(port)), JsonOut.field("count", Nat(count))]
			EmitPort({ port, json }) => [JsonOut.field("port", Text(port)), JsonOut.field("json", Text(json))]
			ClosePort(port) => [JsonOut.field("port", Text(port))]
			FailPort({ port, message }) => [JsonOut.field("port", Text(port)), text(message)]
			ExpectPortSubscriptions({ port, count }) => [JsonOut.field("port", Text(port)), JsonOut.field("count", Nat(count))]
			ExpectSaved({ index, name, text: contents }) => [JsonOut.field("index", Nat(index)), JsonOut.field("name", Text(name)), text(contents)]
			ExpectSaves(n) => [JsonOut.field("count", Nat(n))]
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
		\\  (steps
		\\    (stub-http "feed" :url "/api/a" :status 200 :headers (("content-type" "text/plain")) :body "hi λ")
		\\    (stub-http-reject "x" :kind timeout :detail "")
		\\    (run-effect 2)
		\\    (expect-pending-effects 0)))
	)?
	Str.inspect(spec.steps.map(|s| s.op)) == "[StubHttp({ label: \"feed\", stub: Reply({ body: \"hi λ\", headers: [{ name: \"content-type\", value: \"text/plain\" }], status: 200, url: \"/api/a\" }) }), StubHttp({ label: \"x\", stub: Reject({ detail: \"\", kind: Timeout }) }), RunEffect(2), ExpectPendingEffects(0)]"
}

## Worker steps: a job lost with a fault class, a timeout expired, and the
## pending jobs of a task; each emits its arguments for the browser runner.
expect {
	spec = Scm.parse(
		\\(test "work"
		\\  (steps
		\\    (lose-work 1 app_crash)
		\\    (time-out-work 2)
		\\    (expect-pending-work "example.org/search/filter" 3)))
	)?
	actual =
		\\${Str.inspect(spec.steps.map(|s| s.op))}
		\\${JsonOut.render(Scm.to_json("w", spec))}
	expected =
		\\[LoseWork({ fault: AppCrash, occurrence: 1 }), TimeOutWork(2), ExpectPendingWork({ count: 3, task: "example.org/search/filter" })]
		\\{"id":"w","name":"work","setup":[],"environment":{"url":"/","storage":[],"storage_available":true,"online":true,"visible":true},"steps":[{"op":"lose-work","line":3,"column":5,"count":1,"fault":"app_crash"},{"op":"time-out-work","line":4,"column":5,"count":2},{"op":"expect-pending-work","line":5,"column":5,"task":"example.org/search/filter","count":3}]}
	actual == expected
}

## Every work fault parses and is spelled back as it was written.
expect Scm.work_faults.all(|(name, fault)| Scm.parse("(test \"t\" (steps (lose-work 1 ${name})))").map_ok(|spec| spec.steps.map(|s| s.op)) == Ok([LoseWork({ occurrence: 1, fault })]) and Scm.work_fault_name(fault) == name)

## Worker steps check their arguments.
expect {
	actual =
		\\${problem_of("(test \"t\" (steps (lose-work 1 crashed)))")}
		\\${problem_of("(test \"t\" (steps (lose-work 1 \"app_crash\")))")}
		\\${problem_of("(test \"t\" (steps (lose-work 1)))")}
		\\${problem_of("(test \"t\" (steps (time-out-work -1)))")}
		\\${problem_of("(test \"t\" (steps (expect-pending-work \"\" 1)))")}
		\\${problem_of("(test \"t\" (steps (expect-pending-work filter 1)))")}
	expected =
		\\x.scm:1:31: unknown work fault crashed; a job is lost to contract, resource_limit, out_of_memory, app_crash, expect_failed, unavailable, executor
		\\x.scm:1:31: the work fault must be a bare word, got "app_crash"
		\\x.scm:1:18: lose-work takes 2 argument(s), got 1
		\\x.scm:1:33: the effect occurrence must be a non-negative integer, got -1
		\\x.scm:1:39: the task name must not be empty
		\\x.scm:1:39: the task name must be a string, got filter
	actual == expected
}

## An unknown step is a hard error naming its line and column.
expect problem_of("(test \"t\"\n  (steps\n    (click (label \"a\"))\n    (frobnicate 1)))") == "x.scm:4:5: unknown step frobnicate"

## Setup vocabulary is not a step, and steps are not setup.
expect problem_of("(test \"t\" (steps (local-storage-unavailable)))") == "x.scm:1:18: unknown step local-storage-unavailable"

## Forms neither runner implements are not part of the grammar: each is an
## unknown step or setup form.
expect {
	actual =
		\\${problem_of("(test \"t\" (steps (pointer-down (label \"a\"))))")}
		\\${problem_of("(test \"t\" (steps (key-down (label \"a\") \"Enter\" false)))")}
		\\${problem_of("(test \"t\" (steps (composition-start (label \"a\"))))")}
		\\${problem_of("(test \"t\" (steps (custom-event (label \"a\") \"x\" \"\")))")}
		\\${problem_of("(test \"t\" (steps (expect-session-storage \"k\" \"v\")))")}
		\\${problem_of("(test \"t\" (steps (assert-current-location \"/\")))")}
		\\${problem_of("(test \"t\" (setup (manual-effects)) (steps (mark-metrics)))")}
		\\${problem_of("(test \"t\" (setup (session-storage \"k\" \"v\")) (steps (mark-metrics)))")}
		\\${problem_of("(test \"t\" (setup (stub-http \"f\" :url \"/a\" :status 200 :body \"\")) (steps (mark-metrics)))")}
	expected =
		\\x.scm:1:18: unknown step pointer-down
		\\x.scm:1:18: unknown step key-down
		\\x.scm:1:18: unknown step composition-start
		\\x.scm:1:18: unknown step custom-event
		\\x.scm:1:18: unknown step expect-session-storage
		\\x.scm:1:18: unknown step assert-current-location
		\\x.scm:1:18: unknown setup form manual-effects
		\\x.scm:1:18: unknown setup form session-storage
		\\x.scm:1:18: unknown setup form stub-http
	actual == expected
}

## Live control state is asserted with its own step, not as an attribute.
expect problem_of("(test \"t\" (steps (expect-no-attr (label \"a\") value)))") == "x.scm:1:46: value is live control state, not an attribute; assert it with expect-value"

## Each form is spelled once, and a parsed step spells its own form.
expect {
	names = Scm.step_forms.map(|f| f.name)
	distinct = names.keep_if(|n| names.count_if(|m| m == n) == 1).len() == names.len()
	spec = Scm.parse("(test \"n\" (steps (stub-http-reject \"x\" :kind timeout :detail \"\") (expect-current-location \"/\") (mark-metrics)))") ?? { name: "", setup: [], steps: [] }
	distinct and spec.steps.map(|st| Scm.op_name(st.op)) == ["stub-http-reject", "expect-current-location", "mark-metrics"]
}

## Executable steps are refused inside setup.
expect problem_of("(test \"t\" (setup (click (text \"No\"))) (steps (mark-metrics)))") == "x.scm:1:18: unknown setup form click"

## A form whose head is not `test` is not a spec.
expect problem_of("(suite \"s\" (steps (click (text \"a\"))))") == "x.scm:1:2: a spec starts with `test`"

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
	actual == "{\"id\":\"j-file\",\"name\":\"j\",\"setup\":[{\"op\":\"local-storage\",\"line\":1,\"column\":18,\"key\":\"k\",\"text\":\"v\"}],\"environment\":{\"url\":\"/\",\"storage\":[[\"k\",\"v\"]],\"storage_available\":true,\"online\":true,\"visible\":true},\"steps\":[{\"op\":\"expect-checked\",\"line\":1,\"column\":50,\"loc\":{\"kind\":\"role\",\"role\":\"checkbox\",\"name\":\"A\"},\"value\":true}]}"
}

## Metric names are checked: an unknown one is a parse error, and a known one
## emits the counters it sums.
expect {
	spec = Scm.parse("(test \"m\" (steps (mark-metrics) (expect-metric-delta set_text 2)))")?
	actual =
		\\${problem_of("(test \"t\" (steps (expect-metric-delta-at-most rows_painted 0)))")}
		\\${JsonOut.render(Scm.to_json("m", spec))}
	expected =
		\\x.scm:1:47: unknown metric rows_painted; the metrics are rows_created, rows_removed, rows_reused, rows_updated, rows_moved, create_element, set_text, set_value, set_checked, bind_event, set_metadata, patches_emitted, derived_calls_into_roc, scopes_created, scopes_disposed, dirty_source_roots, each_key_hashes, each_key_compares, effects_issued, effects_delivered, effects_stale, effects_refused, effects_cancelled, effects_reparented, effects_skipped
		\\{"id":"m","name":"m","setup":[],"environment":{"url":"/","storage":[],"storage_available":true,"online":true,"visible":true},"steps":[{"op":"mark-metrics","line":1,"column":18},{"op":"expect-metric-delta","line":1,"column":33,"metric":"set_text","counters":[2,12],"delta":2}]}
	actual == expected
}

## File steps name setup files, which carry a name, a type and contents.
expect {
	text = "(test \"f\" (setup (file \"a.txt\" \"text/plain\" \"ab\" 3) (file \"b.png\" \"image/png\" \"\")) (steps (choose-files (label \"Up\") \"a.txt\" \"b.png\") (drop-files (test-id \"z\") \"a.txt\") (paste-files (test-id \"z\") \"b.png\") (expect-files 3)))"
	parsed = Scm.parse(text)
	setup = parsed.map_ok(|spec| spec.setup.map(|e| e.item))
	steps = parsed.map_ok(|spec| spec.steps.map(|s| s.op))
	setup == Ok([File({ name: "a.txt", mime: "text/plain", text: "ab", repeat: 3 }), File({ name: "b.png", mime: "image/png", text: "", repeat: 1 })]) and steps == Ok([ChooseFiles(Label("Up"), ["a.txt", "b.png"]), DropFiles(TestId("z"), ["a.txt"]), PasteFiles(TestId("z"), ["b.png"]), ExpectFiles(3)])
}

## File steps and setup files check their arguments.
expect {
	bad_name = problem_of("(test \"t\" (setup (file \"d/a.txt\" \"text/plain\" \"\")) (steps (expect-files 0)))")
	no_files = problem_of("(test \"t\" (steps (drop-files (test-id \"z\"))))")
	bad_name.contains("without a directory") and no_files.contains("at least one file name")
}

## A spec bounds a task's output with `max-output-bytes`, and asserts what
## the app saved with `expect-saved` and `expect-saves`; saves are counted
## from 1.
expect {
	spec = Scm.parse("(test \"s\" (setup (max-output-bytes 8)) (steps (expect-saved 1 \"out.txt\" \"AB\") (expect-saves 1)))")?
	zero = problem_of("(test \"s\" (steps (expect-saved 0 \"out.txt\" \"\")))")
	actual =
		\\setup: ${Str.inspect(spec.setup.map(|s| s.item))}
		\\steps: ${Str.inspect(spec.steps.map(|s| s.op))}
		\\zero: ${zero}
	expected =
		\\setup: [MaxOutputBytes(8)]
		\\steps: [ExpectSaved({ index: 1, name: "out.txt", text: "AB" }), ExpectSaves(1)]
		\\zero: x.scm:1:32: saves are counted from 1
	actual == expected
}

## Focus assertions share the same locators and strict arities as the other
## assertions, and emit the operations consumed by the browser runner.
expect {
	spec = Scm.parse("(test \"focus\" (steps (expect-focused (label \"Name\")) (expect-no-focus)))")?
	spec.steps.map(|step| step.op) == [ExpectFocused(Label("Name")), ExpectNoFocus]
}

## A focus assertion's arguments are checked at parse time in both runners.
expect {
	missing = Scm.parse("(test \"t\" (steps (expect-focused)))")
	extra = Scm.parse("(test \"t\" (steps (expect-no-focus (label \"Name\"))))")
	missing.is_err() and extra.is_err()
}

## Unset specs use Boot's defaults, with no independent runner default.
expect {
	spec = Scm.parse("(test \"defaults\" (steps (mark-metrics)))")?
	boot : Core.Boot
	boot = {}
	spec.environment == boot
}

## The parser resolves repeated facts and storage keys in setup order; the
## emitted environment is data and the next-document hook preserves it.
expect {
	spec = Scm.parse("(test \"resolved\" (setup (initial-location \"/a\") (initial-online offline) (initial-visibility hidden) (local-storage \"a\" \"old\") (local-storage \"b\" \"b\") (local-storage \"a\" \"new\")) (steps (mark-metrics)))")?
	expected : Scm.Environment
	expected = { url: "/a", online: Bool.False, visible: Bool.False, storage: [("b", "b"), ("a", "new")] }
	{ resolved: spec.environment, next: Scm.next_document(spec.environment) } == { resolved: expected, next: expected }
}

## Either order of seeding unavailable storage is a parser error at the
## second conflicting form; runners never have to reconstruct this rule.
expect {
	before = Scm.parse("(test \"bad\" (setup (local-storage \"a\" \"v\") (local-storage-unavailable)) (steps (mark-metrics)))")
	after = Scm.parse("(test \"bad\" (setup (local-storage-unavailable) (local-storage \"a\" \"v\")) (steps (mark-metrics)))")
	message = "local-storage seeds storage that local-storage-unavailable says the app cannot read"
	{ before, after } == {
		before: Err({ pos: { line: 1, column: 44 }, message }),
		after: Err({ pos: { line: 1, column: 48 }, message }),
	}
}
