import Dom
import Scm
import JsonOut

## The native `.scm` spec runner.
##
## It drives an app's `Program` — the same `keys`/`init`/`event` record the
## Wasm host calls — with the bytes the browser runtime would send: boot bytes
## at mount, DOM event payloads, and effect results on the effect node
## (design.md, Appendix B). Every assertion reads the `Dom.roc` oracle's model
## of the command stream, or the work record the engine returns with each
## call, never engine state, so a passing spec exercises the protocol the
## browser consumes.
##
## Beside the DOM, the runner models the browser services the engine drives
## through effect commands: the location and history stack, the title, local
## storage, connectivity and page visibility, pending awaited requests, live
## subscriptions, and which element has focus.
##
## - `run-effect N` answers the N-th awaited non-subscription request the app
##   issued (issue order). It must still be pending. Its answer is the first
##   queued stub whose URL equals the request's; a reject stub matches any.
## - A rejected request becomes `Timeout`, or `Network(detail)`.
## - `navigate` and `history-back`/`history-forward` move the location as a
##   user would and deliver the new URL to every live popstate subscription.
##   App pushes and replaces move it without a popstate, as browsers do.
## - `tick-interval MS` delivers `Fired` to every live interval of period MS
##   (and fails when there is none); `set-online` and `set-visibility` change
##   the modelled browser and deliver the new value to every live
##   subscription of that kind.
## - Focus moves as Chrome moves it: `fill`, `focus` and a click on a
##   focusable control focus it, a click elsewhere or `blur` blurs, and each
##   move delivers `blur` to the element losing focus and `focus` to the one
##   gaining it when a handler listens.
## - Work assertions (design.md, "Work assertions") read the engine's work
##   counters (`Scm.metric_names`); at every one the runner also checks that
##   the engine's per-opcode counters agree with the commands the oracle
##   decoded. `expect-updates` counts, per element, its creation plus every
##   later `ATTR`, `HATTR`, `SETTEXT` or `TEXT` that wrote it or a text node
##   directly inside it.
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
		version : U32,
		keys : () -> List(U8),
		init : List(U8) -> (state, List(U8), List(U8)),
		event : state, List(U8), List(U8), U32, U32, List(U8) -> (state, List(U8), List(U8)),
	}

	Sub : [Interval(U32), Pop, OnlineSub, VisibilitySub]

	## The modelled browser around the DOM.
	Browser : {
		loc : Str,
		back : List(Str),
		fwd : List(Str),
		title : Str,
		storage : List({ key : Str, value : Str }),
		online : Bool,
		visible : Bool,
		storage_available : Bool,
		pending : List({ id : U32, url : Str, body : Str }),
		issued : List(U32),
		subs : List({ id : U32, sub : Sub }),
		stubs : List(Scm.Stub),
	}

	## The runner's state: the instance and the buffers it lends back, the
	## oracle's DOM and browser models, the latest work record, the oracle's
	## own opcode counts, per-node write counts (`expect-updates`), the work
	## counters at the last `mark-metrics`, the focused node (index + 1, 0
	## for none), and the value the engine wrote to the focused control that
	## the controlled-input rule holds back until blur.
	S(state) : {
		inst : state,
		buf : List(U8),
		wbuf : List(U8),
		dom : Dom.Model,
		browser : Browser,
		work : Dom.Work,
		ops : List(U64),
		writes : List(U64),
		mark : List(U64),
		focused : U64,
		deferred : Deferred,
	}

	## A control value held back while its control has focus (design.md,
	## "Controlled inputs").
	Deferred : [NoValue, Held(Str)]

	## How a spec ended.
	Outcome : [
		Passed,
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

	flag_byte : Bool -> U8
	flag_byte = |b| if (b) 1 else 0

	## Boot bytes: `url:str count:u32 (key:str value:str)* online:u8
	## visible:u8 storage:u8`, declared keys that hold a value only.
	encode_boot : Str, List({ key : Str, value : Str }), { online : Bool, visible : Bool, storage_available : Bool } -> List(U8)
	encode_boot = |url, kvs, { online, visible, storage_available }| {
		var $b = SpecRunner.put_u32(SpecRunner.put_str([], url), kvs.len().to_u32_wrap())
		for { key, value } in kvs {
			$b = SpecRunner.put_str(SpecRunner.put_str($b, key), value)
		}
		$b.append(SpecRunner.flag_byte(online)).append(SpecRunner.flag_byte(visible)).append(SpecRunner.flag_byte(storage_available))
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
	## (tag 2) with the detail as the browser's message.
	encode_reject : Scm.RejectKind, Str -> List(U8)
	encode_reject = |kind, detail|
		match kind {
			Timeout => [7]
			Network => [2].concat(detail.to_utf8())
		}

	## A popstate result: tag 6 with the URL.
	encode_location : Str -> List(U8)
	encode_location = |url| [6].concat(url.to_utf8())

	# ------------------------------------------------------------ the browser

	## Hand one call's command batch and work record to the oracle and the
	## browser model.
	take : S(state), state, List(U8), List(U8) -> S(state)
	take = |s, inst, cmds, wbuf| {
		s1 = SpecRunner.take_batch(s, inst, cmds)
		{ ..s1, wbuf, work: Dom.decode_work(wbuf) }
	}

	## Hand one command batch to the oracle and the browser model, keeping
	## the last work record (for drivers that call the engine directly and
	## assert no work metrics).
	take_batch : S(state), state, List(U8) -> S(state)
	take_batch = |s, inst, cmds| {
		before = s.dom.nodes.len()
		r = Dom.apply_full(s.dom, cmds)
		var $ops = s.ops
		for op in r.ops {
			$ops = $ops.set(op.to_u64(), ($ops.get(op.to_u64()) ?? 0) + 1) ?? $ops
		}
		var $w = s.writes
		while $w.len() < r.dom.nodes.len() {
			$w = $w.append(0)
		}
		for i in r.written {
			# A node written in the batch that created it counts its creation
			# only.
			if i < before {
				$w = $w.set(i, ($w.get(i) ?? 0) + 1) ?? $w
				n = Dom.node(r.dom, i)
				if n.tag == "" and n.parent != 0 {
					$w = $w.set(n.parent - 1, ($w.get(n.parent - 1) ?? 0) + 1) ?? $w
				}
			}
		}
		held = SpecRunner.hold_focused(s, r.dom, r.values)
		{ ..s, inst, buf: cmds, dom: held.dom, deferred: held.deferred, browser: SpecRunner.absorb(s.browser, r.fx), ops: $ops, writes: $w }
	}

	## The controlled-input rule, as the runtime applies it: a `value` write
	## to the focused control (not a `<select>`) that equals what it shows is
	## a no-op and drops any held value; a differing one is held back, and the
	## control keeps showing what the user typed until blur.
	hold_focused : S(state), Dom.Model, List((U64, Str)) -> { dom : Dom.Model, deferred : Deferred }
	hold_focused = |s, dom, values| {
		if s.focused == 0 or Dom.node(s.dom, s.focused - 1).tag == "select" {
			return { dom, deferred: s.deferred }
		}
		i = s.focused - 1
		shown = Dom.attr_of(Dom.node(s.dom, i), "value")
		var $deferred = s.deferred
		var $wrote = Bool.False
		for (node, v) in values {
			if node == i {
				$wrote = Bool.True
				$deferred = if (v == shown) NoValue else Held(v)
			}
		}
		if $wrote {
			{ dom: Dom.set_attr_on(dom, i, "value", shown), deferred: $deferred }
		} else {
			{ dom, deferred: $deferred }
		}
	}

	## A runner state for an instance mounted outside `mount` (by a driver
	## that calls the engine directly), at `url` with `storage`.
	adopt : state, List(U8), Str, List({ key : Str, value : Str }) -> S(state)
	adopt = |inst, cmds, url, storage| {
		browser = { loc: url, back: [], fwd: [], title: "", storage, online: Bool.True, visible: Bool.True, storage_available: Bool.True, pending: [], issued: [], subs: [], stubs: [] }
		s0 = { inst, buf: [], wbuf: [], dom: Dom.new({}), browser, work: { counters: [], cleanups: [] }, ops: List.repeat(0, 19), writes: [], mark: [], focused: 0, deferred: NoValue }
		SpecRunner.take_batch(s0, inst, cmds)
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
				Http(id, _, url, _, body, _) => { ..b, pending: b.pending.append({ id, url, body }), issued: b.issued.append(id) }
				Get(id, key) => { ..b, pending: b.pending.append({ id, url: "storage:${key}", body: "" }), issued: b.issued.append(id) }
				Timer(id, _) => { ..b, pending: b.pending.append({ id, url: "timer", body: "" }), issued: b.issued.append(id) }
				Interval(id, ms) => { ..b, subs: b.subs.append({ id, sub: Interval(ms) }) }
				Pop(id) => { ..b, subs: b.subs.append({ id, sub: Pop }) }
				OnlineSub(id) => { ..b, subs: b.subs.append({ id, sub: OnlineSub }) }
				VisibilitySub(id) => { ..b, subs: b.subs.append({ id, sub: VisibilitySub }) }
				Cancel(id) => { ..b, pending: b.pending.keep_if(|p| p.id != id), subs: b.subs.keep_if(|x| x.id != id) }
				Push(url) => { ..b, back: b.back.append(b.loc), loc: url, fwd: [] }
				Replace(url) => { ..b, loc: url }
				# Writes to unavailable storage fail in the browser and persist nothing.
				Set(k, v) => if (b.storage_available) { ..b, storage: SpecRunner.set_store(b.storage, k, v) } else b
				Remove(k) => if (b.storage_available) { ..b, storage: b.storage.keep_if(|kv| kv.key != k) } else b
				Title(t) => { ..b, title: t }
				Focus(_, _) => b
			}
		}
		$b
	}

	## Mount the app with the spec's setup.
	start : Program(state), Scm.Spec -> Try(S(state), Str)
	start = |program, spec| {
		if program.version != Dom.protocol_version {
			return Err("the program speaks protocol ${program.version.to_str()}; this runner decodes ${Dom.protocol_version.to_str()}")
		}
		var $url = "/"
		var $storage = []
		var $online = Bool.True
		var $visible = Bool.True
		var $storage_available = Bool.True
		for entry in spec.setup {
			match entry.item {
				ManualEffects => {}
				InitialLocation(url) => {
					$url = url
				}
				LocalStorage({ key, value }) => {
					$storage = SpecRunner.set_store($storage, key, value)
				}
				InitialOnline(o) => {
					$online = o == Online
				}
				InitialVisibility(v) => {
					$visible = v == Visible
				}
				LocalStorageUnavailable => {
					$storage_available = Bool.False
				}
				other => return Err("unsupported in this engine: setup ${Str.inspect(other)}")
			}
		}
		if !$storage_available and !$storage.is_empty() {
			return Err("local-storage seeds storage that local-storage-unavailable says the app cannot read")
		}
		Ok(SpecRunner.mount_in(program, { url: $url, storage: $storage, online: $online, visible: $visible, storage_available: $storage_available }))
	}

	## Mount the app at `url` with `storage` as local storage; the app's
	## declared keys that hold a value become its boot storage.
	mount : Program(state), Str, List({ key : Str, value : Str }) -> S(state)
	mount = |program, url, storage| SpecRunner.mount_in(program, { url, storage, online: Bool.True, visible: Bool.True, storage_available: Bool.True })

	mount_in : Program(state), { url : Str, storage : List({ key : Str, value : Str }), online : Bool, visible : Bool, storage_available : Bool } -> S(state)
	mount_in = |program, { url, storage, online, visible, storage_available }| {
		declared = SpecRunner.decode_keys((program.keys)())
		boot_kvs = declared.keep_oks(|k| storage.find_first(|kv| kv.key == k))
		(inst, cmds, wbuf) = (program.init)(SpecRunner.encode_boot(url, boot_kvs, { online, visible, storage_available }))
		browser = { loc: url, back: [], fwd: [], title: "", storage, online, visible, storage_available, pending: [], issued: [], subs: [], stubs: [] }
		s0 = { inst, buf: [], wbuf: [], dom: Dom.new({}), browser, work: { counters: [], cleanups: [] }, ops: List.repeat(0, 19), writes: [], mark: [], focused: 0, deferred: NoValue }
		SpecRunner.take(s0, inst, cmds, wbuf)
	}

	## Dispatch event `ev` with `payload` from DOM node index `i`, as the
	## runtime's delegated listener does.
	fire : Program(state), S(state), U64, Str, Str -> Try(S(state), Str)
	fire = |program, s, i, ev, payload|
		match Dom.target(s.dom, i, ev) {
			Err(_) => Err("no ${ev} handler")
			Ok((node, h)) => Ok(SpecRunner.send(program, s, node, h, payload.to_utf8()))
		}

	## Dispatch `ev` if a handler listens for it on the way up from node `i`.
	fire_if : Program(state), S(state), U64, Str, Str -> S(state)
	fire_if = |program, s, i, ev, payload| SpecRunner.fire(program, s, i, ev, payload) ?? s

	## One host call.
	send : Program(state), S(state), U32, U32, List(U8) -> S(state)
	send = |program, s, node, h, payload| {
		(inst, cmds, wbuf) = (program.event)(s.inst, s.buf, s.wbuf, node, h, payload)
		SpecRunner.take(s, inst, cmds, wbuf)
	}

	## Deliver an effect result to request `id`.
	deliver : Program(state), S(state), U32, List(U8) -> S(state)
	deliver = |program, s, id, payload| SpecRunner.send(program, s, SpecRunner.fx_node, id, payload)

	## Deliver `payload` to every live subscription `pick` selects.
	broadcast : Program(state), S(state), ({ id : U32, sub : Sub } -> Bool), List(U8) -> S(state)
	broadcast = |program, s0, pick, payload| {
		var $s = s0
		for x in s0.browser.subs.keep_if(pick) {
			$s = SpecRunner.deliver(program, $s, x.id, payload)
		}
		$s
	}

	## The browser moved to `browser.loc` on its own: every popstate
	## subscription hears it.
	popstate : Program(state), S(state) -> S(state)
	popstate = |program, s| SpecRunner.broadcast(program, s, |x| x.sub == Pop, SpecRunner.encode_location(s.browser.loc))

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

	## Fire one tick of every live interval of period `ms`.
	tick : Program(state), S(state), U64 -> S(state)
	tick = |program, s, ms| SpecRunner.broadcast(program, s, |x| x.sub == Interval(ms.to_u32_wrap()), [5])

	live_intervals : S(state), U64 -> U64
	live_intervals = |s, ms| s.browser.subs.count_if(|x| x.sub == Interval(ms.to_u32_wrap()))

	# ---------------------------------------------------------------- focus

	## Whether Chrome focuses node `i` when it is clicked or `.focus()`ed.
	focusable : Dom.DNode -> Bool
	focusable = |n| {
		tag_ok = n.tag == "button" or n.tag == "input" or n.tag == "select" or n.tag == "textarea" or (n.tag == "a" and Dom.attr_of(n, "href") != "") or Dom.attr_of(n, "tabindex") != ""
		tag_ok and Dom.attr_of(n, "disabled") != "true"
	}

	## Move focus to node index `to` (+1; 0 blurs), delivering `blur` to the
	## element losing it and `focus` to the one gaining it, each with the
	## element's value, when a handler listens. No events when focus stays.
	## A value held back on the control losing focus lands first, before its
	## `blur` handler runs (the runtime applies it in a capturing listener).
	move_focus : Program(state), S(state), U64 -> S(state)
	move_focus = |program, s0, to| {
		if s0.focused == to {
			s0
		} else {
			from = s0.focused
			landed = match s0.deferred {
				Held(v) if from != 0 => SpecRunner.set_attr(s0, from - 1, "value", v)
				_ => s0
			}
			s1 = { ..landed, focused: to, deferred: NoValue }
			s2 = if (from == 0) s1 else SpecRunner.fire_if(program, s1, from - 1, "blur", Dom.attr_of(Dom.node(s1.dom, from - 1), "value"))
			if (to == 0) s2 else SpecRunner.fire_if(program, s2, to - 1, "focus", Dom.attr_of(Dom.node(s2.dom, to - 1), "value"))
		}
	}

	## A mouse click moves focus to the control under it, or away.
	click_focus : Program(state), S(state), U64 -> S(state)
	click_focus = |program, s, i| SpecRunner.move_focus(program, s, if (SpecRunner.focusable(Dom.node(s.dom, i))) i + 1 else 0)

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

	## A work metric's value now: the sum of the counters it names.
	metric_now : S(state), Str -> Try(I64, Str)
	metric_now = |s, metric| {
		counters = Scm.metric_counters(metric) ? |_| Scm.unknown_metric(metric)
		Ok(counters.fold(0.I64, |acc, k| acc + (s.work.counters.get(k) ?? 0).to_i64_wrap()))
	}

	## A metric's change since the last `mark-metrics`, after checking that
	## the engine's opcode counters agree with the commands the oracle
	## decoded.
	metric_delta : S(state), Str -> Try(I64, Str)
	metric_delta = |s, metric| {
		if s.mark.is_empty() {
			return Err("no mark-metrics before this step")
		}
		SpecRunner.check_counters(s)?
		now = SpecRunner.metric_now(s, metric)?
		counters = Scm.metric_counters(metric) ? |_| Scm.unknown_metric(metric)
		then = counters.fold(0.I64, |acc, k| acc + (s.mark.get(k) ?? 0).to_i64_wrap())
		Ok(now - then)
	}

	## The engine's per-opcode work counters agree with the commands the
	## oracle decoded from every batch so far.
	check_counters : S(state) -> Try({}, Str)
	check_counters = |s| {
		var $op = 1.U64
		while $op <= 18 {
			engine = s.work.counters.get($op) ?? 0
			oracle = s.ops.get($op) ?? 0
			if engine != oracle {
				return Err("the engine counted ${engine.to_str()} ${Dom.op_name($op.to_u8_wrap())} commands but emitted ${oracle.to_str()}")
			}
			$op = $op + 1
		}
		Ok({})
	}

	## Run one step. `Err(Unsupported(_))` is a step this runner cannot honour;
	## it is never skipped silently.
	one : Program(state), S(state), Scm.Op -> Try(S(state), [Assertion(Str), Unsupported(Str)])
	one = |program, s, op| {
		dom = s.dom
		b = s.browser
		need_el = |loc| SpecRunner.need(dom, loc).map_err(|m| Assertion(m))
		check = |ok, msg| if (ok) Ok(s) else Err(Assertion(msg))
		fire_ev = |st, i, ev, payload| SpecRunner.fire(program, st, i, ev, payload).map_err(|m| Assertion(m))
		disabled = |i| Dom.attr_of(Dom.node(dom, i), "disabled") == "true"
		match op {
			Click(loc) => {
				i = need_el(loc)?
				# A browser delivers no click to a disabled control.
				if disabled(i) {
					Ok(s)
				} else {
					fire_ev(SpecRunner.click_focus(program, s, i), i, "click", "")
				}
			}
			RealClick(loc) => {
				i = need_el(loc)?
				if disabled(i) {
					return Err(Assertion("${Scm.show_loc(loc)} is disabled"))
				}
				SpecRunner.real_click(program, s, i).map_err(|m| Assertion(m))
			}
			Fill(loc, v) => {
				i = need_el(loc)?
				s1 = SpecRunner.move_focus(program, s, i + 1)
				# An input that echoes the held value makes it moot.
				s2 = if (s1.deferred == Held(v)) { ..s1, deferred: NoValue } else s1
				fire_ev(SpecRunner.set_attr(s2, i, "value", v), i, "input", v)
			}
			Focus(loc) => Ok(SpecRunner.move_focus(program, s, need_el(loc)? + 1))
			Blur(loc) => {
				i = need_el(loc)?
				if (s.focused == i + 1) Ok(SpecRunner.move_focus(program, s, 0)) else Ok(s)
			}
			Check(loc) => {
				i = need_el(loc)?
				SpecRunner.set_checked(program, SpecRunner.click_focus(program, s, i), i, Bool.True).map_err(|m| Assertion(m))
			}
			Uncheck(loc) => {
				i = need_el(loc)?
				SpecRunner.set_checked(program, SpecRunner.click_focus(program, s, i), i, Bool.False).map_err(|m| Assertion(m))
			}
			SelectOption(loc, v) => {
				i = need_el(loc)?
				n = Dom.node(dom, i)
				if n.tag != "select" {
					return Err(Assertion("${Scm.show_loc(loc)} is not a <select>"))
				}
				has_option = Dom.find(dom, i, |o| o.tag == "option" and Dom.attr_of(o, "value") == v).is_ok()
				if !has_option {
					return Err(Assertion("${Scm.show_loc(loc)} has no option ${JsonOut.quote(v)}"))
				}
				fire_ev(SpecRunner.set_attr(s, i, "value", v), i, "change", v)
			}
			Change(loc, v) => {
				i = need_el(loc)?
				n = Dom.node(dom, i)
				kind = Dom.attr_of(n, "type")
				if n.tag == "input" and (kind == "radio" or kind == "checkbox") {
					if Dom.attr_of(n, "value") != v {
						return Err(Assertion("${Scm.show_loc(loc)} has value ${JsonOut.quote(Dom.attr_of(n, "value"))}, not ${JsonOut.quote(v)}"))
					}
					fire_ev(SpecRunner.check_on(s, i), i, "change", "true")
				} else {
					fire_ev(SpecRunner.set_attr(s, i, "value", v), i, "change", v)
				}
			}
			Submit(loc) => {
				i = need_el(loc)?
				if Dom.node(dom, i).tag != "form" {
					return Err(Assertion("${Scm.show_loc(loc)} is not a <form>"))
				}
				fire_ev(s, i, "submit", "")
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
			ExpectUpdates(loc, n) => {
				i = need_el(loc)?
				got = 1 + (s.writes.get(i) ?? 0)
				check(got == n, "${Scm.show_loc(loc)} was written ${got.to_str()} times (its creation and every later update), expected ${n.to_str()}")
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
			TickInterval(ms) =>
				if SpecRunner.live_intervals(s, ms) == 0 {
					Err(Assertion("no live interval with period ${ms.to_str()} ms"))
				} else {
					Ok(SpecRunner.tick(program, s, ms))
				}
			TickIntervalIfActive(ms) => Ok(SpecRunner.tick(program, s, ms))
			ExpectInterval({ period_ms, count }) => {
				got = SpecRunner.live_intervals(s, period_ms)
				check(got == count, "${got.to_str()} live intervals with period ${period_ms.to_str()} ms, expected ${count.to_str()}")
			}
			ExpectCleanup({ name, count }) => {
				got = s.work.cleanups.find_first(|(n, _)| n == name).map_ok(|(_, k)| k) ?? 0
				check(got == count, "cleanup ${JsonOut.quote(name)} ran ${got.to_str()} times, expected ${count.to_str()}")
			}
			SetOnline(o) => {
				on = o == Online
				if on == b.online {
					Ok(s)
				} else {
					s1 = { ..s, browser: { ..b, online: on } }
					Ok(SpecRunner.broadcast(program, s1, |x| x.sub == OnlineSub, [8, SpecRunner.flag_byte(on)]))
				}
			}
			SetVisibility(v) => {
				vis = v == Visible
				if vis == b.visible {
					Ok(s)
				} else {
					s1 = { ..s, browser: { ..b, visible: vis } }
					Ok(SpecRunner.broadcast(program, s1, |x| x.sub == VisibilitySub, [9, SpecRunner.flag_byte(vis)]))
				}
			}
			MarkMetrics => Ok({ ..s, mark: s.work.counters })
			ExpectMetricDelta({ metric, delta }) => {
				got = SpecRunner.metric_delta(s, metric).map_err(|m| Assertion(m))?
				check(got == delta, "${metric} changed by ${got.to_str()}, expected ${delta.to_str()}")
			}
			ExpectMetricDeltaAtMost({ metric, delta }) => {
				got = SpecRunner.metric_delta(s, metric).map_err(|m| Assertion(m))?
				check(got <= delta, "${metric} changed by ${got.to_str()}, expected at most ${delta.to_str()}")
			}
			other => Err(Unsupported(Scm.op_name(other)))
		}
	}

	## Mark node `i` checked; a radio unchecks the other radios of its group
	## (same `name`), as the browser does without events.
	check_on : S(state), U64 -> S(state)
	check_on = |s, i| {
		n = Dom.node(s.dom, i)
		group = Dom.attr_of(n, "name")
		s1 = if Dom.attr_of(n, "type") == "radio" and group != "" {
			var $d = s.dom
			var $k = 0.U64
			while $k < $d.nodes.len() {
				m = Dom.node($d, $k)
				if $k != i and m.tag == "input" and Dom.attr_of(m, "type") == "radio" and Dom.attr_of(m, "name") == group and Dom.attr_of(m, "checked") == "true" {
					$d = Dom.set_attr_on($d, $k, "checked", "false")
				}
				$k = $k + 1
			}
			{ ..s, dom: $d }
		} else {
			s
		}
		SpecRunner.set_attr(s1, i, "checked", "true")
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

	## A real mouse click, in Chrome's order (design.md, "The `.scm` spec
	## language"): `mousedown`, then focus moves (the default action of the
	## press), then `mouseup` and `click`,
	## then the browser's default action: a checkbox toggles and a radio
	## checks (each with `change`), and a submit button submits its form. A
	## click that reaches no handler and has no default action fails.
	real_click : Program(state), S(state), U64 -> Try(S(state), Str)
	real_click = |program, s0, i| {
		n = Dom.node(s0.dom, i)
		kind = Dom.attr_of(n, "type")
		s1 = SpecRunner.fire_if(program, s0, i, "mousedown", "")
		s2 = SpecRunner.click_focus(program, s1, i)
		s3 = SpecRunner.fire_if(program, s2, i, "mouseup", "")
		clicked = Dom.target(s3.dom, i, "click").is_ok()
		s4 = SpecRunner.fire_if(program, s3, i, "click", "")
		if n.tag == "input" and kind == "checkbox" {
			want = Dom.attr_of(Dom.node(s4.dom, i), "checked") != "true"
			Ok(SpecRunner.fire_if(program, SpecRunner.set_attr(s4, i, "checked", SpecRunner.bool_str(want)), i, "change", SpecRunner.bool_str(want)))
		} else if n.tag == "input" and kind == "radio" {
			if Dom.attr_of(Dom.node(s4.dom, i), "checked") == "true" {
				Ok(s4)
			} else {
				Ok(SpecRunner.fire_if(program, SpecRunner.check_on(s4, i), i, "change", "true"))
			}
		} else if n.tag == "button" and (kind == "" or kind == "submit") and SpecRunner.form_of(s4.dom, i).is_ok() {
			form = SpecRunner.form_of(s4.dom, i) ?? 0
			Ok(SpecRunner.fire_if(program, s4, form, "submit", ""))
		} else if clicked {
			Ok(s4)
		} else {
			Err("no click handler and no default action for this element")
		}
	}

	## The nearest `<form>` at or above node `i`.
	form_of : Dom.Model, U64 -> Try(U64, [NoForm])
	form_of = |dom, i| {
		n = Dom.node(dom, i)
		if n.tag == "form" {
			Ok(i)
		} else if n.parent == 0 {
			Err(NoForm)
		} else {
			SpecRunner.form_of(dom, n.parent - 1)
		}
	}

	## Replay one spec from a fresh mount.
	run : Program(state), Scm.Spec -> Outcome
	run = |program, spec| {
		var $s = match SpecRunner.start(program, spec) {
			Ok(s) => s
			Err(message) => return Failed({ step: 0, at: spec.steps.first() ?? crash "a parsed spec has steps", kind: Unsupported, message })
		}
		var $i = 0.U64
		for step in spec.steps {
			match SpecRunner.one(program, $s, step.op) {
				Ok(s2) => {
					$s = s2
				}
				Err(Assertion(message)) => return Failed({ step: $i, at: step, kind: Assertion, message })
				Err(Unsupported(name)) => return Failed({ step: $i, at: step, kind: Unsupported, message: "${name}: unsupported in this runner" })
			}
			$i = $i + 1
		}
		Passed
	}

	# ------------------------------------------------------------------ CLI

	## The host services the `spec` command uses, passed in by the test
	## program (the test platform's `Cli`), so this package stays pure.
	Io : { read_file! : Str => List(U8), stdout! : Str => {}, stderr! : Str => {}, now_ns! : () => U64 }

	Options : { filter : Str, emit_steps : Bool, files : List(Str) }

	usage : Str
	usage = "usage: TARGET spec [--filter GLOB] [--emit-steps] FILE.scm...\n"

	parse_args : List(Str) -> Try(Options, Str)
	parse_args = |args| {
		var $o = { filter: "*", emit_steps: Bool.False, files: [] }
		var $i = 0.U64
		while $i < args.len() {
			a = args.get($i) ?? ""
			if a == "--filter" {
				$o = { ..$o, filter: args.get($i + 1) ? |_| "--filter needs a pattern" }
				$i = $i + 2
			} else if a == "--emit-steps" {
				$o = { ..$o, emit_steps: Bool.True }
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

	result_line : { id : Str, name : Str, status : Str, duration_ns : U64, failure : JsonOut.Value } -> Str
	result_line = |r|
		JsonOut.render(
			Object([
				JsonOut.field("protocol", Text("roc-signals/spec-result/v2")),
				JsonOut.field("id", Text(r.id)),
				JsonOut.field("name", Text(r.name)),
				JsonOut.field("status", Text(r.status)),
				JsonOut.field("duration_ns", Nat(r.duration_ns)),
				JsonOut.field("failure", r.failure),
			]),
		)

	## The `spec` command: parse every file, then either emit the parsed steps
	## as JSON lines (`--emit-steps`) or run each spec and print one
	## `spec-result` JSON line per spec. Exit 0 when nothing failed.
	main! : Program(state), Io, List(Str) => I32
	main! = |program, io, args| {
		opts = match SpecRunner.parse_args(args) {
			Ok(o) => o
			Err(msg) => {
				(io.stderr!)("${msg}\n${SpecRunner.usage}")
				return 2
			}
		}
		var $counts = { passed: 0.U64, failed: 0.U64, error: 0.U64 }
		for path in opts.files {
			id = SpecRunner.id_of(path)
			if SpecRunner.glob(opts.filter, id) {
				text = Str.from_utf8((io.read_file!)(path)) ?? ""
				t0 = (io.now_ns!)()
				match Scm.parse(text) {
					Err(problem) => {
						$counts = { ..$counts, error: $counts.error + 1 }
						(io.stdout!)(
							"${SpecRunner.result_line({ id, name: "", status: "error", duration_ns: 0, failure: SpecRunner.failure_json("parse", "parse", Scm.show_problem(path, problem), 0, problem.pos) })}\n",
						)
					}
					Ok(spec) if opts.emit_steps => {
						(io.stdout!)("${JsonOut.render(Scm.to_json(id, spec))}\n")
					}
					Ok(spec) => {
						outcome = SpecRunner.run(program, spec)
						dt = (io.now_ns!)() - t0
						line = match outcome {
							Passed => {
								$counts = { ..$counts, passed: $counts.passed + 1 }
								SpecRunner.result_line({ id, name: spec.name, status: "passed", duration_ns: dt, failure: Null })
							}
							Failed({ step, at, kind, message }) => {
								$counts = { ..$counts, failed: $counts.failed + 1 }
								kind_name = if (kind == Unsupported) "unsupported" else "assertion"
								full = "${path}:${at.pos.line.to_str()}:${at.pos.column.to_str()}: ${Scm.op_name(at.op)}: ${message}"
								SpecRunner.result_line({ id, name: spec.name, status: "failed", duration_ns: dt, failure: SpecRunner.failure_json("step", kind_name, full, step, at.pos) })
							}
						}
						(io.stdout!)("${line}\n")
					}
				}
			}
		}
		c = $counts
		if !opts.emit_steps {
			(io.stderr!)("specs: ${c.passed.to_str()} passed, ${c.failed.to_str()} failed, ${c.error.to_str()} error\n")
		}
		if (c.failed + c.error == 0) 0 else 1
	}
}

## Wire encoding: strings are length-prefixed, integers little-endian, and
## the boot bytes end with the online, visible and storage flags.
expect SpecRunner.encode_boot("/a", [{ key: "k", value: "v" }], { online: Bool.False, visible: Bool.True, storage_available: Bool.False }) == [2, 0, 0, 0, '/', 'a', 1, 0, 0, 0, 1, 0, 0, 0, 'k', 1, 0, 0, 0, 'v', 0, 1, 0]

## An HTTP result carries status, headers and the body as the rest.
expect SpecRunner.encode_http(422, [{ name: "a", value: "b" }], "x") == [1, 0xA6, 0x01, 1, 0, 0, 0, 1, 0, 0, 0, 'a', 1, 0, 0, 0, 'b', 'x']

## Rejections are a timeout or a network failure carrying the detail.
expect SpecRunner.encode_reject(Timeout, "") == [7] and SpecRunner.encode_reject(Network, "offline") == [2, 'o', 'f', 'f', 'l', 'i', 'n', 'e']

## Declared storage keys decode from `count:u32 (key:str)*`.
expect SpecRunner.decode_keys([2, 0, 0, 0, 1, 0, 0, 0, 'a', 2, 0, 0, 0, 'b', 'c']) == ["a", "bc"]

## Filters match ids shell-style.
expect {
	actual = [SpecRunner.glob("*", "x"), SpecRunner.glob("add*", "adding-a-field"), SpecRunner.glob("a?c", "abc"), SpecRunner.glob("*move", "cross-column-move"), SpecRunner.glob("x*", "y")]
	actual == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.False]
}

## Options parse; unknown options (the retired `--pending-phase3` among them)
## and empty file lists are refused.
expect {
	o = SpecRunner.parse_args(["--filter", "a*", "x.scm"]) ?? { filter: "", emit_steps: Bool.False, files: [] }
	o.filter == "a*" and o.files == ["x.scm"] and SpecRunner.parse_args(["--pending-phase3", "x.scm"]).is_err() and SpecRunner.parse_args([]).is_err()
}
