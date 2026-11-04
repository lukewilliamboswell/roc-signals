import pf.Cli
import Dom
import Scm
import JsonOut

## The native `.scm` spec runner.
##
## It drives an app's `Program` — the same `keys`/`init`/`event` record the
## Wasm host calls — with the bytes the browser runtime would send: boot bytes
## at mount, DOM event payloads, and effect results on the effect node
## (design.md, Appendix B). Every assertion reads the `Dom.roc` oracle's model
## of the command stream, never engine state, so a passing spec exercises the
## protocol the browser consumes.
##
## Beside the DOM, the runner models the browser services the engine drives
## through effect commands: the location and history stack, the title, local
## storage, pending awaited requests and live subscriptions.
##
## - `run-effect N` answers the N-th awaited non-subscription request the app
##   issued (issue order). It must still be pending. Its answer is the first
##   queued stub whose URL equals the request's; a reject stub matches any.
## - A rejected request becomes `Timeout`, or `Network(text)` where the text
##   is the original platform's inspected error, such as `Network("offline")`.
## - `navigate` and `history-back`/`history-forward` move the location as a
##   user would and deliver the new URL to every live popstate subscription.
##   App pushes and replaces move it without a popstate, as browsers do.
## - Work assertions (`Scm.is_metric`) need engine counters that do not exist
##   yet. They fail as unsupported, or, with `--pending-phase3`, are recorded
##   and the spec reports `pending-phase3` instead of passing.
##
## Locators follow the original simulated DOM: `label` is `aria-label`,
## `test-id` is `data-testid`, `role` is the explicit `role` attribute or the
## implicit role (button, a → link, section → region, form, dialog,
## h1–h6 → heading) with the accessible name (`aria-label`, else the text
## content), and `text` is a text node whose content is exactly the string.
## The first match in document order wins.
SpecRunner := [].{

	## An app as its host sees it (`Engine.Program`, structurally).
	Program(state) : {
		keys : () -> List(U8),
		init : List(U8) -> (state, List(U8)),
		event : state, List(U8), U32, U32, List(U8) -> (state, List(U8)),
	}

	Mode : [Strict, PendingPhase3]

	## The modelled browser around the DOM.
	Browser : {
		loc : Str,
		back : List(Str),
		fwd : List(Str),
		title : Str,
		storage : List({ key : Str, value : Str }),
		pending : List({ id : U32, url : Str }),
		issued : List(U32),
		subs : List(U32),
		stubs : List(Scm.Stub),
	}

	S(state) : { inst : state, buf : List(U8), dom : Dom.Model, browser : Browser }

	## How a spec ended. `Pending` lists the work steps that were recorded
	## rather than run (`--pending-phase3` only).
	Outcome : [
		Passed,
		Pending(List(Scm.Step)),
		Failed({ step : U64, at : Scm.Step, kind : FailKind, message : Str }),
	]

	FailKind : [Assertion, Unsupported]

	## The effect node of the wire protocol (design.md, Appendix B).
	fx_node : U32
	fx_node = 0xFFFF_FFFF

	# ------------------------------------------------------------ wire bytes

	put_u32 : List(U8), U32 -> List(U8)
	put_u32 = |b, n| b.concat([n.bitwise_and(0xFF).to_u8_wrap(), n.shr_zf_wrap(8).bitwise_and(0xFF).to_u8_wrap(), n.shr_zf_wrap(16).bitwise_and(0xFF).to_u8_wrap(), n.shr_zf_wrap(24).to_u8_wrap()])

	put_str : List(U8), Str -> List(U8)
	put_str = |b, s| {
		bytes = s.to_utf8()
		SpecRunner.put_u32(b, bytes.len().to_u32_wrap()).concat(bytes)
	}

	get_u32 : List(U8), U64 -> Try(U32, [Short])
	get_u32 = |b, at| {
		b0 = b.get(at) ? |_| Short
		b1 = b.get(at + 1) ? |_| Short
		b2 = b.get(at + 2) ? |_| Short
		b3 = b.get(at + 3) ? |_| Short
		Ok(b0.to_u32() + b1.to_u32().shl_wrap(8) + b2.to_u32().shl_wrap(16) + b3.to_u32().shl_wrap(24))
	}

	## The declared storage keys: `count:u32 (key:str)*`.
	decode_keys : List(U8) -> List(Str)
	decode_keys = |b| {
		n = SpecRunner.get_u32(b, 0) ?? crash "contract: storage key list is truncated"
		var $at = 4.U64
		var $keys = []
		var $i = 0.U32
		while $i < n {
			len = (SpecRunner.get_u32(b, $at) ?? crash "contract: storage key list is truncated").to_u64()
			key = Str.from_utf8(b.sublist({ start: $at + 4, len })) ?? crash "contract: storage key is not UTF-8"
			$keys = $keys.append(key)
			$at = $at + 4 + len
			$i = $i + 1
		}
		$keys
	}

	## Boot bytes: `url:str count:u32 (key:str value:str)*`, declared keys
	## that hold a value only.
	encode_boot : Str, List({ key : Str, value : Str }) -> List(U8)
	encode_boot = |url, kvs| {
		var $b = SpecRunner.put_u32(SpecRunner.put_str([], url), kvs.len().to_u32_wrap())
		for { key, value } in kvs {
			$b = SpecRunner.put_str(SpecRunner.put_str($b, key), value)
		}
		$b
	}

	## An HTTP result payload: tag 1, `status:u16 n:u32 (name:str value:str)* body:rest`.
	encode_http : U16, List(Scm.Header), Str -> List(U8)
	encode_http = |status, headers, body| {
		var $b = [1, status.bitwise_and(0xFF).to_u8_wrap(), status.shr_zf_wrap(8).to_u8_wrap()]
		$b = SpecRunner.put_u32($b, headers.len().to_u32_wrap())
		for { name, value } in headers {
			$b = SpecRunner.put_str(SpecRunner.put_str($b, name), value)
		}
		$b.concat(body.to_utf8())
	}

	## A rejected request's result payload: `Timeout` (tag 7) or `Network`
	## (tag 2) with the original platform's inspected error text.
	encode_reject : Scm.RejectKind, Str -> List(U8)
	encode_reject = |kind, detail| {
		name = match kind {
			Timeout => return [7]
			Network => "Network"
			InvalidRequest => "InvalidRequest"
			TooLarge => "TooLarge"
			Unavailable => "Unavailable"
		}
		[2].concat("${name}(${JsonOut.quote(detail)})".to_utf8())
	}

	## A popstate result: tag 6 with the URL.
	encode_location : Str -> List(U8)
	encode_location = |url| [6].concat(url.to_utf8())

	# ------------------------------------------------------------ the browser

	## Hand one command batch to the DOM model and the browser model.
	take : S(state), state, List(U8) -> S(state)
	take = |s, inst, cmds| {
		(dom, _, fx) = Dom.apply_fx(s.dom, cmds)
		{ inst, buf: cmds, dom, browser: SpecRunner.absorb(s.browser, fx) }
	}

	set_store : List({ key : Str, value : Str }), Str, Str -> List({ key : Str, value : Str })
	set_store = |l, key, value| l.keep_if(|kv| kv.key != key).append({ key, value })

	## Apply one batch's effect commands to the modelled browser.
	absorb : Browser, List(Dom.FxCmd) -> Browser
	absorb = |b0, fx| {
		var $b = b0
		for c in fx {
			b = $b
			$b = match c {
				Http(id, _, url, _, _, _) => { ..b, pending: b.pending.append({ id, url }), issued: b.issued.append(id) }
				Get(id, key) => { ..b, pending: b.pending.append({ id, url: "storage:${key}" }), issued: b.issued.append(id) }
				Timer(id, _) => { ..b, pending: b.pending.append({ id, url: "timer" }), issued: b.issued.append(id) }
				Interval(id, _) => { ..b, subs: b.subs.append(id) }
				Pop(id) => { ..b, subs: b.subs.append(id) }
				Cancel(id) => { ..b, pending: b.pending.keep_if(|p| p.id != id), subs: b.subs.keep_if(|x| x != id) }
				Push(url) => { ..b, back: b.back.append(b.loc), loc: url, fwd: [] }
				Replace(url) => { ..b, loc: url }
				Set(k, v) => { ..b, storage: SpecRunner.set_store(b.storage, k, v) }
				Remove(k) => { ..b, storage: b.storage.keep_if(|kv| kv.key != k) }
				Title(t) => { ..b, title: t }
				Focus(_, _) => b
			}
		}
		$b
	}

	## Mount the app with the spec's setup.
	start : Program(state), Scm.Spec -> Try(S(state), Str)
	start = |program, spec| {
		var $url = "/"
		var $storage = []
		for entry in spec.setup {
			match entry.item {
				ManualEffects => {}
				InitialLocation(url) => {
					$url = url
				}
				LocalStorage({ key, value }) => {
					$storage = SpecRunner.set_store($storage, key, value)
				}
				other => return Err("unsupported in this engine yet: setup ${Str.inspect(other)}")
			}
		}
		declared = SpecRunner.decode_keys((program.keys)())
		storage = $storage
		boot_kvs = declared.keep_oks(|k| storage.find_first(|kv| kv.key == k))
		(inst, cmds) = (program.init)(SpecRunner.encode_boot($url, boot_kvs))
		browser = { loc: $url, back: [], fwd: [], title: "", storage, pending: [], issued: [], subs: [], stubs: [] }
		(dom, _, fx) = Dom.apply_fx(Dom.new({}), cmds)
		Ok({ inst, buf: cmds, dom, browser: SpecRunner.absorb(browser, fx) })
	}

	## Dispatch event `ev` with `payload` from DOM node index `i`, as the
	## runtime's delegated listener does.
	fire : Program(state), S(state), U64, Str, Str -> Try(S(state), Str)
	fire = |program, s, i, ev, payload|
		match Dom.target(s.dom, i, ev) {
			Err(_) => Err("no ${ev} handler")
			Ok((node, h)) => {
				(inst, cmds) = (program.event)(s.inst, s.buf, node, h, payload.to_utf8())
				Ok(SpecRunner.take(s, inst, cmds))
			}
		}

	## Deliver an effect result to request `id`.
	deliver : Program(state), S(state), U32, List(U8) -> S(state)
	deliver = |program, s, id, payload| {
		(inst, cmds) = (program.event)(s.inst, s.buf, SpecRunner.fx_node, id, payload)
		SpecRunner.take(s, inst, cmds)
	}

	## The browser moved to `browser.loc` on its own: every popstate
	## subscription hears it.
	popstate : Program(state), S(state) -> S(state)
	popstate = |program, s0| {
		var $s = s0
		for id in s0.browser.subs {
			$s = SpecRunner.deliver(program, $s, id, SpecRunner.encode_location(s0.browser.loc))
		}
		$s
	}

	run_effect : Program(state), S(state), U64 -> Try(S(state), Str)
	run_effect = |program, s, n| {
		b = s.browser
		id = b.issued.get(n - 1) ? |_| "effect occurrence ${n.to_str()} was never issued (${b.issued.len().to_str()} issued)"
		p = b.pending.find_first(|q| q.id == id) ? |_| "effect occurrence ${n.to_str()} is not pending (cancelled or done)"
		k = b.stubs.find_first_index(
			|stub|
				match stub {
					Reply(r) => r.url == p.url
					Reject(_) => Bool.True
				},
		) ? |_| "no spec stub for ${p.url}"
		stub = b.stubs.get(k) ?? crash "SpecRunner.run_effect: the index was just found"
		payload = match stub {
			Reply({ status, headers, body, .. }) => SpecRunner.encode_http(status, if (headers.is_empty()) [{ name: "content-type", value: "application/json" }] else headers, body)
			Reject({ kind, detail }) => SpecRunner.encode_reject(kind, detail)
		}
		s1 = { ..s, browser: { ..b, stubs: b.stubs.drop_at(k), pending: b.pending.keep_if(|q| q.id != id) } }
		Ok(SpecRunner.deliver(program, s1, id, payload))
	}

	# ------------------------------------------------------------- locators

	implicit_role : Dom.DNode -> Str
	implicit_role = |n| {
		explicit = Dom.attr_of(n, "role")
		if explicit != "" {
			explicit
		} else {
			match n.tag {
				"button" => "button"
				"a" => "link"
				"section" => "region"
				"form" => "form"
				"dialog" => "dialog"
				"h1" | "h2" | "h3" | "h4" | "h5" | "h6" => "heading"
				_ => ""
			}
		}
	}

	accessible_name : Dom.Model, Dom.DNode -> Str
	accessible_name = |dom, n| {
		l = Dom.attr_of(n, "aria-label")
		if (l != "") l else Str.join_with(n.kids.map(|k| Dom.text_of(dom, k)), "")
	}

	matches : Dom.Model, Dom.DNode, Scm.Loc -> Bool
	matches = |dom, n, loc|
		match loc {
			Label(x) => n.tag != "" and Dom.attr_of(n, "aria-label") == x
			TestId(x) => n.tag != "" and Dom.attr_of(n, "data-testid") == x
			Role({ role, name }) => n.tag != "" and SpecRunner.implicit_role(n) == role and SpecRunner.accessible_name(dom, n) == name
			Text(x) => n.tag == "" and n.text == x
		}

	find : Dom.Model, Scm.Loc -> Try(U64, [NotFound])
	find = |dom, loc| Dom.find(dom, dom.root, |n| SpecRunner.matches(dom, n, loc))

	need : Dom.Model, Scm.Loc -> Try(U64, Str)
	need = |dom, loc| SpecRunner.find(dom, loc).map_err(|_| "no element ${Scm.show_loc(loc)}")

	bool_str : Bool -> Str
	bool_str = |b| if (b) "true" else "false"

	set_attr : S(state), U64, Str, Str -> S(state)
	set_attr = |s, i, name, v| { ..s, dom: Dom.set_attr_on(s.dom, i, name, v) }

	# ----------------------------------------------------------------- steps

	## Run one step. `Err(Unsupported(_))` is a step this runner cannot honour
	## yet; it is never skipped silently.
	one : Program(state), S(state), Scm.Op -> Try(S(state), [Assertion(Str), Unsupported(Str)])
	one = |program, s, op| {
		dom = s.dom
		b = s.browser
		need_el = |loc| SpecRunner.need(dom, loc).map_err(|m| Assertion(m))
		check = |ok, msg| if (ok) Ok(s) else Err(Assertion(msg))
		fire_ev = |st, i, ev, payload| SpecRunner.fire(program, st, i, ev, payload).map_err(|m| Assertion(m))
		match op {
			Click(loc) => {
				i = need_el(loc)?
				# A browser delivers no click to a disabled control.
				if (Dom.attr_of(Dom.node(dom, i), "disabled") == "true") Ok(s) else fire_ev(s, i, "click", "")
			}
			Fill(loc, v) => {
				i = need_el(loc)?
				fire_ev(SpecRunner.set_attr(s, i, "value", v), i, "input", v)
			}
			Check(loc) => SpecRunner.set_checked(program, s, need_el(loc)?, Bool.True).map_err(|m| Assertion(m))
			Uncheck(loc) => SpecRunner.set_checked(program, s, need_el(loc)?, Bool.False).map_err(|m| Assertion(m))
			SelectOption(loc, v) => {
				i = need_el(loc)?
				fire_ev(SpecRunner.set_attr(s, i, "value", v), i, "change", v)
			}
			ExpectText(loc, want) => {
				got = Dom.text_of(dom, need_el(loc)?)
				check(got == want, "${Scm.show_loc(loc)} text ${JsonOut.quote(got)}, expected ${JsonOut.quote(want)}")
			}
			ExpectValue(loc, want) => {
				got = Dom.attr_of(Dom.node(dom, need_el(loc)?), "value")
				check(got == want, "${Scm.show_loc(loc)} value ${JsonOut.quote(got)}, expected ${JsonOut.quote(want)}")
			}
			ExpectChecked(loc, want) => {
				got = Dom.attr_of(Dom.node(dom, need_el(loc)?), "checked") == "true"
				check(got == want, "${Scm.show_loc(loc)} checked ${SpecRunner.bool_str(got)}, expected ${SpecRunner.bool_str(want)}")
			}
			ExpectDisabled(loc, want) => {
				got = Dom.attr_of(Dom.node(dom, need_el(loc)?), "disabled") == "true"
				check(got == want, "${Scm.show_loc(loc)} disabled ${SpecRunner.bool_str(got)}, expected ${SpecRunner.bool_str(want)}")
			}
			ExpectVisible(loc) => {
				_ = need_el(loc)?
				Ok(s)
			}
			ExpectAbsent(loc) => check(SpecRunner.find(dom, loc).is_err(), "${Scm.show_loc(loc)} is present")
			ExpectAttr({ target, name, value }) => {
				got = Dom.attr_of(Dom.node(dom, need_el(target)?), name)
				check(got == value, "${Scm.show_loc(target)} ${name}=${JsonOut.quote(got)}, expected ${JsonOut.quote(value)}")
			}
			ExpectNoAttr({ target, name }) => {
				got = Dom.attr_of(Dom.node(dom, need_el(target)?), name)
				check(got == "", "${Scm.show_loc(target)} has ${name}=${JsonOut.quote(got)}")
			}
			ExpectLocation(want) => check(b.loc == want, "location ${JsonOut.quote(b.loc)}, expected ${JsonOut.quote(want)}")
			ExpectTitle(want) => check(b.title == want, "title ${JsonOut.quote(b.title)}, expected ${JsonOut.quote(want)}")
			ExpectLocalStorage({ key, value }) => {
				got = b.storage.find_first(|kv| kv.key == key).map_ok(|kv| JsonOut.quote(kv.value)) ?? "<missing>"
				check(got == JsonOut.quote(value), "local storage ${key} = ${got}, expected ${JsonOut.quote(value)}")
			}
			ExpectNoLocalStorage(key) => check(!b.storage.any(|kv| kv.key == key), "local storage ${key} is present")
			ExpectPendingEffects(n) => check(b.pending.len() == n, "expected ${n.to_str()} pending effects, got ${b.pending.len().to_str()}")
			RunEffect(n) => SpecRunner.run_effect(program, s, n).map_err(|m| Assertion(m))
			StubHttp({ stub, .. }) => Ok({ ..s, browser: { ..b, stubs: b.stubs.append(stub) } })
			Navigate(url) => Ok(SpecRunner.popstate(program, { ..s, browser: { ..b, back: b.back.append(b.loc), loc: url, fwd: [] } }))
			HistoryBack =>
				match b.back.last() {
					Ok(prev) => Ok(SpecRunner.popstate(program, { ..s, browser: { ..b, back: b.back.drop_last(1), fwd: [b.loc].concat(b.fwd), loc: prev } }))
					Err(_) => Err(Assertion("history-back with no history"))
				}
			HistoryForward =>
				match b.fwd.first() {
					Ok(next) => Ok(SpecRunner.popstate(program, { ..s, browser: { ..b, fwd: b.fwd.drop_first(1), back: b.back.append(b.loc), loc: next } }))
					Err(_) => Err(Assertion("history-forward with no forward entry"))
				}
			other => Err(Unsupported(Scm.op_name(other)))
		}
	}

	## Check or uncheck a control as a click would: no event when it already
	## has the wanted state.
	set_checked : Program(state), S(state), U64, Bool -> Try(S(state), Str)
	set_checked = |program, s, i, want|
		if (Dom.attr_of(Dom.node(s.dom, i), "checked") == "true") == want {
			Ok(s)
		} else {
			SpecRunner.fire(program, SpecRunner.set_attr(s, i, "checked", SpecRunner.bool_str(want)), i, "change", SpecRunner.bool_str(want))
		}

	## Replay one spec from a fresh mount.
	run : Program(state), Scm.Spec, Mode -> Outcome
	run = |program, spec, mode| {
		var $s = match SpecRunner.start(program, spec) {
			Ok(s) => s
			Err(message) => return Failed({ step: 0, at: spec.steps.first() ?? crash "a parsed spec has steps", kind: Unsupported, message })
		}
		var $pending = []
		var $i = 0.U64
		for step in spec.steps {
			if Scm.is_metric(step.op) {
				if mode == PendingPhase3 {
					$pending = $pending.append(step)
				} else {
					return Failed({ step: $i, at: step, kind: Unsupported, message: "${Scm.op_name(step.op)}: unsupported in this engine yet (work counters, intervals and cleanups land in Phase 3)" })
				}
			} else {
				match SpecRunner.one(program, $s, step.op) {
					Ok(s2) => {
						$s = s2
					}
					Err(Assertion(message)) => return Failed({ step: $i, at: step, kind: Assertion, message })
					Err(Unsupported(name)) => return Failed({ step: $i, at: step, kind: Unsupported, message: "${name}: unsupported in this engine yet" })
				}
			}
			$i = $i + 1
		}
		if ($pending.is_empty()) Passed else Pending($pending)
	}

	# ------------------------------------------------------------------ CLI

	Options : { filter : Str, emit_steps : Bool, mode : Mode, files : List(Str) }

	usage : Str
	usage = "usage: TARGET spec [--filter GLOB] [--emit-steps] [--pending-phase3] FILE.scm...\n"

	parse_args : List(Str) -> Try(Options, Str)
	parse_args = |args| {
		var $o = { filter: "*", emit_steps: Bool.False, mode: Strict, files: [] }
		var $i = 0.U64
		while $i < args.len() {
			a = args.get($i) ?? ""
			if a == "--filter" {
				$o = { ..$o, filter: args.get($i + 1) ? |_| "--filter needs a pattern" }
				$i = $i + 2
			} else if a == "--emit-steps" {
				$o = { ..$o, emit_steps: Bool.True }
				$i = $i + 1
			} else if a == "--pending-phase3" {
				$o = { ..$o, mode: PendingPhase3 }
				$i = $i + 1
			} else if a.starts_with("--") {
				return Err("unknown option ${a}")
			} else {
				$o = { ..$o, files: $o.files.append(a) }
				$i = $i + 1
			}
		}
		if ($o.files.is_empty()) Err("no spec files given") else Ok($o)
	}

	## A spec's id: its file name without the directory or `.scm`.
	id_of : Str -> Str
	id_of = |path| {
		base = path.split_on("/").last() ?? path
		base.drop_suffix(".scm")
	}

	## Shell-style matching: `*` any run, `?` any one byte.
	glob : Str, Str -> Bool
	glob = |pattern, text| SpecRunner.glob_bytes(pattern.to_utf8(), text.to_utf8())

	glob_bytes : List(U8), List(U8) -> Bool
	glob_bytes = |p, t|
		match p {
			[] => t.is_empty()
			['*', .. as rest] => SpecRunner.glob_bytes(rest, t) or (!t.is_empty() and SpecRunner.glob_bytes(p, t.drop_first(1)))
			['?', .. as rest] => !t.is_empty() and SpecRunner.glob_bytes(rest, t.drop_first(1))
			[c, .. as rest] => t.first() == Ok(c) and SpecRunner.glob_bytes(rest, t.drop_first(1))
		}

	failure_json : Str, Str, Str, U64, Scm.Pos -> JsonOut.Value
	failure_json = |phase, kind, message, step, pos|
		Object([
			JsonOut.field("phase", Text(phase)),
			JsonOut.field("kind", Text(kind)),
			JsonOut.field("message", Text(message)),
			JsonOut.field("step", Nat(step)),
			JsonOut.field("line", Nat(pos.line)),
			JsonOut.field("column", Nat(pos.column)),
		])

	result_line : { id : Str, name : Str, status : Str, duration_ns : U64, failure : JsonOut.Value, pending : List(Scm.Step) } -> Str
	result_line = |r|
		JsonOut.render(
			Object([
				JsonOut.field("protocol", Text("roc-signals/spec-result/v2")),
				JsonOut.field("id", Text(r.id)),
				JsonOut.field("name", Text(r.name)),
				JsonOut.field("status", Text(r.status)),
				JsonOut.field("duration_ns", Nat(r.duration_ns)),
				JsonOut.field("failure", r.failure),
				JsonOut.field("pending_steps", Array(r.pending.map(|p| Object([JsonOut.field("op", Text(Scm.op_name(p.op))), JsonOut.field("line", Nat(p.pos.line))])))),
			]),
		)

	## The `spec` command: parse every file, then either emit the parsed steps
	## as JSON lines (`--emit-steps`) or run each spec and print one
	## `spec-result` JSON line per spec. Exit 0 when nothing failed.
	main! : Program(state), List(Str) => I32
	main! = |program, args| {
		opts = match SpecRunner.parse_args(args) {
			Ok(o) => o
			Err(msg) => {
				Cli.stderr!("${msg}\n${SpecRunner.usage}")
				return 2
			}
		}
		var $counts = { passed: 0.U64, failed: 0.U64, error: 0.U64, pending: 0.U64, pending_steps: 0.U64 }
		for path in opts.files {
			id = SpecRunner.id_of(path)
			if SpecRunner.glob(opts.filter, id) {
				text = Str.from_utf8(Cli.read_file!(path)) ?? ""
				t0 = Cli.now_ns!()
				match Scm.parse(text) {
					Err(problem) => {
						$counts = { ..$counts, error: $counts.error + 1 }
						Cli.stdout!(
							"${SpecRunner.result_line({ id, name: "", status: "error", duration_ns: 0, failure: SpecRunner.failure_json("parse", "parse", Scm.show_problem(path, problem), 0, problem.pos), pending: [] })}\n",
						)
					}
					Ok(spec) if opts.emit_steps => {
						Cli.stdout!("${JsonOut.render(Scm.to_json(id, spec))}\n")
					}
					Ok(spec) => {
						outcome = SpecRunner.run(program, spec, opts.mode)
						dt = Cli.now_ns!() - t0
						line = match outcome {
							Passed => {
								$counts = { ..$counts, passed: $counts.passed + 1 }
								SpecRunner.result_line({ id, name: spec.name, status: "passed", duration_ns: dt, failure: Null, pending: [] })
							}
							Pending(steps) => {
								$counts = { ..$counts, pending: $counts.pending + 1, pending_steps: $counts.pending_steps + steps.len() }
								SpecRunner.result_line({ id, name: spec.name, status: "pending-phase3", duration_ns: dt, failure: Null, pending: steps })
							}
							Failed({ step, at, kind, message }) => {
								$counts = { ..$counts, failed: $counts.failed + 1 }
								kind_name = if (kind == Unsupported) "unsupported" else "assertion"
								full = "${path}:${at.pos.line.to_str()}:${at.pos.column.to_str()}: ${Scm.op_name(at.op)}: ${message}"
								SpecRunner.result_line({ id, name: spec.name, status: "failed", duration_ns: dt, failure: SpecRunner.failure_json("step", kind_name, full, step, at.pos), pending: [] })
							}
						}
						Cli.stdout!("${line}\n")
					}
				}
			}
		}
		c = $counts
		if !opts.emit_steps {
			Cli.stderr!("specs: ${c.passed.to_str()} passed, ${c.failed.to_str()} failed, ${c.error.to_str()} error, ${c.pending.to_str()} pending-phase3 (${c.pending_steps.to_str()} work steps pending)\n")
		}
		if (c.failed + c.error == 0) 0 else 1
	}
}

## Wire encoding: strings are length-prefixed, integers little-endian.
expect SpecRunner.encode_boot("/a", [{ key: "k", value: "v" }]) == [2, 0, 0, 0, '/', 'a', 1, 0, 0, 0, 1, 0, 0, 0, 'k', 1, 0, 0, 0, 'v']

## An HTTP result carries status, headers and the body as the rest.
expect SpecRunner.encode_http(422, [{ name: "a", value: "b" }], "x") == [1, 0xA6, 0x01, 1, 0, 0, 0, 1, 0, 0, 0, 'a', 1, 0, 0, 0, 'b', 'x']

## Rejections are a timeout or a network failure with the inspected error text.
expect {
	actual = Str.from_utf8(SpecRunner.encode_reject(Network, "offline").drop_first(1)) ?? ""
	SpecRunner.encode_reject(Timeout, "") == [7] and actual == "Network(\"offline\")"
}

## Declared storage keys decode from `count:u32 (key:str)*`.
expect SpecRunner.decode_keys([2, 0, 0, 0, 1, 0, 0, 0, 'a', 2, 0, 0, 0, 'b', 'c']) == ["a", "bc"]

## Filters match ids shell-style.
expect {
	actual = [SpecRunner.glob("*", "x"), SpecRunner.glob("add*", "adding-a-field"), SpecRunner.glob("a?c", "abc"), SpecRunner.glob("*move", "cross-column-move"), SpecRunner.glob("x*", "y")]
	actual == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.False]
}

## Options parse; unknown options and empty file lists are refused.
expect {
	o = SpecRunner.parse_args(["--filter", "a*", "--pending-phase3", "x.scm"]) ?? { filter: "", emit_steps: Bool.False, mode: Strict, files: [] }
	o.filter == "a*" and o.mode == PendingPhase3 and o.files == ["x.scm"] and SpecRunner.parse_args(["--bogus", "x.scm"]).is_err() and SpecRunner.parse_args([]).is_err()
}
