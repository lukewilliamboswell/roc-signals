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
## through effect commands: the location, the history stack and the document
## behind each entry, the title, local storage, connectivity and page
## visibility, pending awaited requests, live subscriptions, and which element
## has focus. The browser is the reference: every step means what the browser
## runner (`tests/browser/replay.mjs`) does in Chrome (design.md, "The `.scm`
## spec language"), and `one` matches every step of the grammar.
##
## - Effects are always manual. `stub-http` stages one answer; `run-effect N`
##   answers the N-th awaited HTTP request, timer or worker job the current
##   document issued (issue order), which must still be pending: a timer
##   fires, a worker job runs its program (the `spec` command runs it in a
##   child process, `Io.work!`, so a crash loses only the job, as in a
##   worker; `one` runs it in process), and an HTTP request takes the staged
##   answer, whose URL must be the request's (a
##   reject answers any). Storage reads answer by themselves, from storage, in
##   the turn after the call that issued them.
## - A rejected request becomes `Timeout`, or `Network(detail)`.
## - A spec's time is manual: a worker job's deadline expires only through
##   `time-out-work`, and `lose-work` answers a pending job lost with a fault
##   class without running it.
## - A navigation to a URL that differs from the current one only in its
##   fragment stays in the document: a new history entry, and the URL goes to
##   every live popstate subscription. Any other navigation loads a new
##   document: the app mounts afresh at that URL with the same local storage.
##   `history-back`/`history-forward` move within the document, and refuse to
##   cross into another. App pushes and replaces move the location without a
##   popstate, as browsers do.
## - `tick-interval MS` delivers `Fired` to every live interval of period MS
##   (and fails when there is none); `set-online` and `set-visibility` change
##   the modelled browser and deliver the new value to every live
##   subscription of that kind.
## - A click is a real mouse click: `mousedown`, focus moves to the nearest
##   focusable element (or away), `mouseup`, `click`, then the default action
##   unless the dispatched click handler prevented it: a checkbox toggles, a
##   radio checks (each with `input` and `change`), a submit button submits
##   its form if the form's controls are valid, and a link navigates.
## - Focus moves as Chrome moves it, and each move delivers `change` to a text
##   control the user changed since it gained focus, then `blur` to the
##   element losing focus and `focus` to the one gaining it, when handlers
##   listen.
## - `fill` is Playwright's: it types into an enabled text input or textarea
##   that can hold the value, as one `input` event.
## - Work assertions (design.md, "Work assertions") read the engine's work
##   counters (`Scm.metric_names`); at every one the runner also checks that
##   the engine's per-opcode counters agree with the commands the oracle
##   decoded. `expect-updates` counts, per element, its creation plus every
##   later `ATTR`, `HATTR`, `SETTEXT` or `TEXT` that wrote it or a text node
##   directly inside it.
##
## Locators follow the browser runner's `locate.js`: `label` is `aria-label`,
## `test-id` is `data-testid`, `role` is the explicit `role` attribute or the
## implicit role (button, a → link, section → region, form, dialog,
## h1–h6 → heading) with the accessible name (`aria-label`, else the text
## content), and `text` is a text node whose content is exactly the string,
## naming the element that holds it. The first match in document order wins.
SpecRunner := [].{

	## An app as its host sees it: `Core.driver` of its `Engine.Program`.
	Program(state) : {
		version : U32,
		keys : () -> List(U8),
		init : List(U8) -> (state, List(U8), List(U8)),
		event : state, List(U8), List(U8), U32, U32, List(U8) -> (state, List(U8), List(U8)),

		## A `:files` event: its file record and the handles minted for it.
		files : state, List(U8), List(U8), U32, U32, List(U8), List(Box(U64)) -> (state, List(U8), List(U8)),

		## A worker instance's entry: `name:str input:rest` to output bytes.
		## Programs are pure, so the runner runs a job in process.
		work : List(U8), List(List(U8)) -> List(U8),

		## The engine's settle check (`Core.settled`): `Err` holds the
		## commands a pass over every layer emitted on a discarded copy.
		settled : state -> Try({}, { cmds : List(U8), note : Str }),
	}

	Sub : [Interval(U32), Pop, OnlineSub, VisibilitySub, PortSub(Str, Str)]

	## A history entry: its URL and the document it belongs to.
	Entry : { url : Str, doc : U64 }

	## An awaited request still waiting for `run-effect`: an HTTP request (its
	## URL and body), a timer, or a worker job (its program and input).
	Pending : { id : U32, url : Str, body : Str, kind : PendingKind }

	## What `run-effect` does for a pending request.
	PendingKind : [
		HttpRequest,
		TimerRequest,
		WorkRequest({ program : Str, input : List(U8), deadline_ms : U32, files : List({ token : U64, start : U64, len : U64 }) }),

		## A read of a file into the page: mode 1 bytes, 2 text.
		ReadRequest({ mode : U8, file : { token : U64, start : U64, len : U64 }, max_bytes : U64 }),

		## An HTTP request whose body is a file's range; `run-effect` answers
		## it with the staged stub, as an HTTP request.
		UploadRequest({ token : U64, start : U64, len : U64 }),

		## A SHA-256 digest of a file's range, which the host computes.
		DigestRequest({ token : U64, start : U64, len : U64 }),

		## A URL that shows a file's range.
		UrlRequest({ token : U64, start : U64, len : U64 }),

		## A call on a port, answered with `answer-port`.
		PortRequest({ port : Str, json : Str, timeout_ms : U32 }),
	]

	## The most bytes a digest or a page read reads: the runtime's default
	## `maxFileBytes`.
	max_digest_bytes : U64
	max_digest_bytes = 256 * 1024 * 1024

	## The modelled browser around the DOM. `doc` numbers the current document;
	## a cross-document navigation mounts the app afresh in the next one.
	Browser : {
		loc : Str,
		doc : U64,
		back : List(Entry),
		fwd : List(Entry),
		title : Str,
		storage : List({ key : Str, value : Str }),
		online : Bool,
		visible : Bool,
		storage_available : Bool,
		pending : List(Pending),
		issued : List(U32),
		gets : List({ id : U32, key : Str }),
		subs : List({ id : U32, sub : Sub }),
		stub : [NoStub, Staged(Scm.Stub)],

		## The spec's setup files, and the handle each file the app was given
		## was minted under (a file given twice has two handles).
		files : List(SetupFile),
		given : List({ token : U64, name : Str }),

		## The port commands the app sent in this document, in order.
		port_log : List({ port : Str, json : Str }),
	}

	## A setup file: its name, media type and contents.
	SetupFile : { name : Str, mime : Str, bytes : List(U8) }

	## The runner's state: the instance and the buffers it lends back, the
	## oracle's DOM and browser models, the latest work record, the oracle's
	## own opcode counts, per-node write counts (`expect-updates`), the work
	## counters at the last `mark-metrics`, the focused node (index + 1, 0
	## for none) and the value it showed when it gained focus, and the value
	## the engine wrote to the focused control that the controlled-input rule
	## holds back until blur.
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
		focus_value : Str,
		deferred : Deferred,
	}

	## A control value held back while its control has focus (design.md,
	## "Controlled inputs").
	Deferred : [NoValue, Held(Str)]

	## How a spec ended.
	Outcome : [
		Passed,
		Failed({ step : U64, at : Scm.Step, message : Str }),
	]

	## The effect node of the wire protocol (design.md, Appendix B).
	fx_node : U32
	fx_node = 0xFFFF_FFFF

	# ------------------------------------------------------------ wire bytes

	put_u32 : List(U8), U32 -> List(U8)
	put_u32 = |b, n| b.concat([n.bitwise_and(0xFF).to_u8_wrap(), n.shr_zf_wrap(8).bitwise_and(0xFF).to_u8_wrap(), n.shr_zf_wrap(16).bitwise_and(0xFF).to_u8_wrap(), n.shr_zf_wrap(24).to_u8_wrap()])

	put_u64 : List(U8), U64 -> List(U8)
	put_u64 = |b, n| SpecRunner.put_u32(SpecRunner.put_u32(b, n.to_u32_wrap()), n.shr_zf_wrap(32).to_u32_wrap())

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
	## A lost worker job's result payload: tag 11 and the fault class, as the
	## runtime numbers it (design.md, Appendix B).
	encode_lost : Scm.WorkFault -> List(U8)
	encode_lost = |fault|
		[
			11,
			match fault {
				Contract => 1
				ResourceLimit => 2
				OutOfMemory => 3
				AppCrash => 4
				ExpectFailed => 5
				Unavailable => 6
				Executor => 7
			},
		]

	## The pending worker job that is the N-th effect occurrence, for
	## `lose-work` and `time-out-work`.
	pending_job : S(state), U64 -> Try({ id : U32, deadline_ms : U32 }, Str)
	pending_job = |s, n| {
		b = s.browser
		id = b.issued.get(n - 1) ? |_| "effect occurrence ${n.to_str()} was never issued (${b.issued.len().to_str()} issued)"
		p = b.pending.find_first(|q| q.id == id) ? |_| "effect occurrence ${n.to_str()} is not pending (cancelled or done)"
		match p.kind {
			WorkRequest({ deadline_ms, .. }) => Ok({ id, deadline_ms })
			HttpRequest => Err("effect occurrence ${n.to_str()} is an HTTP request, not a worker job")
			TimerRequest => Err("effect occurrence ${n.to_str()} is a timer, not a worker job")
			ReadRequest(_) => Err("effect occurrence ${n.to_str()} is a file read, not a worker job")
			UploadRequest(_) => Err("effect occurrence ${n.to_str()} is an upload, not a worker job")
			DigestRequest(_) => Err("effect occurrence ${n.to_str()} is a digest, not a worker job")
			UrlRequest(_) => Err("effect occurrence ${n.to_str()} is a file URL, not a worker job")
			PortRequest({ port, .. }) => Err("effect occurrence ${n.to_str()} is a call on port ${JsonOut.quote(port)}, not a worker job")
		}
	}

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
		browser = SpecRunner.fresh_browser({ url, storage, online: Bool.True, visible: Bool.True, storage_available: Bool.True })
		s0 = SpecRunner.fresh(inst, browser)
		SpecRunner.take_batch(s0, inst, cmds)
	}

	## The modelled browser of a fresh document at `url`.
	fresh_browser : { url : Str, storage : List({ key : Str, value : Str }), online : Bool, visible : Bool, storage_available : Bool } -> Browser
	fresh_browser = |{ url, storage, online, visible, storage_available }| {
		loc: url,
		doc: 0,
		back: [],
		fwd: [],
		title: "",
		storage,
		online,
		visible,
		storage_available,
		pending: [],
		issued: [],
		gets: [],
		subs: [],
		stub: NoStub,
		files: [],
		given: [],
		port_log: [],
	}

	## A runner state for instance `inst` before its first batch.
	fresh : state, Browser -> S(state)
	fresh = |inst, browser| { inst, buf: [], wbuf: [], dom: Dom.new({}), browser, work: { counters: [], cleanups: [] }, ops: List.repeat(0, 20), writes: [], mark: [], focused: 0, focus_value: "", deferred: NoValue }

	set_store : List({ key : Str, value : Str }), Str, Str -> List({ key : Str, value : Str })
	set_store = |l, key, value| l.keep_if(|kv| kv.key != key).append({ key, value })

	## Apply one batch's effect commands to the modelled browser.
	absorb : Browser, List(Dom.FxCmd) -> Browser
	absorb = |b0, fx| {
		var $b = b0
		for c in fx {
			b = $b
			$b = match c {
				Http(id, _, url, _, body, _) => { ..b, pending: b.pending.append({ id, url, body, kind: HttpRequest }), issued: b.issued.append(id) }
				Get(id, key) => { ..b, gets: b.gets.append({ id, key }) }
				Timer(id, _) => { ..b, pending: b.pending.append({ id, url: "timer", body: "", kind: TimerRequest }), issued: b.issued.append(id) }
				Work(id, program, input, deadline_ms) => { ..b, pending: b.pending.append({ id, url: "work", body: "", kind: WorkRequest({ program, input, deadline_ms, files: [] }) }), issued: b.issued.append(id) }
				WorkFiles(id, files) => {
					attach = |p| if (p.id == id) {
						..p,
						kind: match p.kind {
							WorkRequest(w) => WorkRequest({ ..w, files })
							other => other
						},
					} else p
					{ ..b, pending: b.pending.map(attach) }
				}
				Interval(id, ms) => { ..b, subs: b.subs.append({ id, sub: Interval(ms) }) }
				Pop(id) => { ..b, subs: b.subs.append({ id, sub: Pop }) }
				OnlineSub(id) => { ..b, subs: b.subs.append({ id, sub: OnlineSub }) }
				VisibilitySub(id) => { ..b, subs: b.subs.append({ id, sub: VisibilitySub }) }
				Cancel(id) => { ..b, pending: b.pending.keep_if(|p| p.id != id), subs: b.subs.keep_if(|x| x.id != id) }
				Push(url) => { ..b, back: b.back.append({ url: b.loc, doc: b.doc }), loc: SpecRunner.resolve_in_document(b.loc, url), fwd: [] }
				Replace(url) => { ..b, loc: SpecRunner.resolve_in_document(b.loc, url) }
				# Writes to unavailable storage fail in the browser and persist nothing.
				Set(k, v) => if (b.storage_available) { ..b, storage: SpecRunner.set_store(b.storage, k, v) } else b
				Remove(k) => if (b.storage_available) { ..b, storage: b.storage.keep_if(|kv| kv.key != k) } else b
				Title(t) => { ..b, title: t }
				Focus(_, _) => b
				FileRead(id, mode, file, max_bytes) => { ..b, pending: b.pending.append({ id, url: "read", body: "", kind: ReadRequest({ mode, file, max_bytes }) }), issued: b.issued.append(id) }
				Upload(id, _, url, _, file, _) => { ..b, pending: b.pending.append({ id, url, body: "", kind: UploadRequest(file) }), issued: b.issued.append(id) }
				Digest(id, _, file) => { ..b, pending: b.pending.append({ id, url: "digest", body: "", kind: DigestRequest(file) }), issued: b.issued.append(id) }
				FileUrl(id, file) => { ..b, pending: b.pending.append({ id, url: "url", body: "", kind: UrlRequest(file) }), issued: b.issued.append(id) }
				PortSend(port, msg) => { ..b, port_log: b.port_log.append({ port, json: msg.json }) }
				PortCall(id, port, msg, timeout_ms) => { ..b, pending: b.pending.append({ id, url: "port", body: "", kind: PortRequest({ port, json: msg.json, timeout_ms }) }), issued: b.issued.append(id) }
				PortListen(id, port, msg) => { ..b, subs: b.subs.append({ id, sub: PortSub(port, msg.json) }) }
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
		var $files = []
		for entry in spec.setup {
			match entry.item {
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
				File({ name, mime, text, repeat }) => {
					if $files.any(|f| f.name == name) {
						return Err("file \"${name}\" is declared twice")
					}
					$files = $files.append({ name, mime, bytes: List.repeat(text.to_utf8(), repeat).join() })
				}
			}
		}
		if !$storage_available and !$storage.is_empty() {
			return Err("local-storage seeds storage that local-storage-unavailable says the app cannot read")
		}
		s0 = SpecRunner.mount_in(program, { url: $url, storage: $storage, online: $online, visible: $visible, storage_available: $storage_available })
		b0 = s0.browser
		Ok({ ..s0, browser: { ..b0, files: $files } })
	}

	## Mount the app at `url` with `storage` as local storage; the app's
	## declared keys that hold a value become its boot storage.
	mount : Program(state), Str, List({ key : Str, value : Str }) -> S(state)
	mount = |program, url, storage| SpecRunner.mount_in(program, { url, storage, online: Bool.True, visible: Bool.True, storage_available: Bool.True })

	mount_in : Program(state), { url : Str, storage : List({ key : Str, value : Str }), online : Bool, visible : Bool, storage_available : Bool } -> S(state)
	mount_in = |program, { url, storage, online, visible, storage_available }| {
		declared = SpecRunner.decode_keys((program.keys)())
		boot_kvs = declared.keep_oks(|k| storage.find_first(|kv| kv.key == k))
		(inst, cmds, wbuf) = (program.init)(SpecRunner.encode_boot(url, if (storage_available) boot_kvs else [], { online, visible, storage_available }))
		s0 = SpecRunner.fresh(inst, SpecRunner.fresh_browser({ url, storage, online, visible, storage_available }))
		SpecRunner.answer_gets(program, SpecRunner.take(s0, inst, cmds, wbuf))
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

	## One host call, then the storage reads it issued, each answered in a turn
	## of its own as the runtime answers them.
	send : Program(state), S(state), U32, U32, List(U8) -> S(state)
	send = |program, s, node, h, payload| {
		(inst, cmds, wbuf) = (program.event)(s.inst, s.buf, s.wbuf, node, h, payload)
		SpecRunner.answer_gets(program, SpecRunner.take(s, inst, cmds, wbuf))
	}

	## Answer every storage read waiting for its turn: the stored value, or
	## `Missing` when there is none or storage is unavailable.
	answer_gets : Program(state), S(state) -> S(state)
	answer_gets = |program, s0| {
		var $s = s0
		while !$s.browser.gets.is_empty() {
			b = $s.browser
			g = b.gets.first() ?? crash "SpecRunner.answer_gets: not empty"
			found = if (b.storage_available) b.storage.find_first(|kv| kv.key == g.key) else Err(NotFound)
			payload = match found {
				Ok(kv) => [3].concat(kv.value.to_utf8())
				Err(_) => [4]
			}
			$s = SpecRunner.deliver(program, { ..$s, browser: { ..b, gets: b.gets.drop_first(1) } }, g.id, payload)
		}
		$s
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

	## A worker job a step runs: its request id and its payload,
	## `name:str input:rest`, as a worker instance receives it.
	Job : { id : U32, payload : List(U8), files : List(List(U8)) }

	## The bytes of the files a job names, from the setup files given under
	## their tokens: what a worker reads into its memory. A token no setup
	## file was given under (a handle minted without the host) reads empty.
	job_files : Browser, List({ token : U64, start : U64, len : U64 }) -> List(List(U8))
	job_files = |b, refs| refs.map(|r| SpecRunner.file_bytes(b, r))

	## The bytes of a handle's range, from the setup file it was given under.
	file_bytes : Browser, { token : U64, start : U64, len : U64 } -> List(U8)
	file_bytes = |b, { token, start: from, len }| {
		name = (b.given.find_first(|g| g.token == token) ?? { token, name: "" }).name
		bytes = (b.files.find_first(|f| f.name == name) ?? { name, mime: "", bytes: [] }).bytes
		bytes.sublist({ start: from, len })
	}

	## The result payload of a page read, as the runtime answers it
	## (design.md, Appendix B): tag 16 with the bytes, 17 with the bytes as
	## text (the engine checks they are UTF-8), or 13 with reason 2 when the
	## range is more than the read's `max_bytes` or the runtime's default
	## `maxFileBytes`, which a spec cannot change.
	read_result : Browser, U8, { token : U64, start : U64, len : U64 }, U64 -> List(U8)
	read_result = |b, mode, file, max_bytes|
		if file.len > max_bytes or file.len > SpecRunner.max_digest_bytes {
			[13, 2]
		} else {
			[if (mode == 1) 16 else 17].concat(SpecRunner.file_bytes(b, file))
		}

	## The result payload of a file URL: tag 19 and a URL naming the handle
	## and the range. Chrome's is a `blob:` URL of its own making, so a spec
	## asserts what the app does with one, not its text.
	url_result : { token : U64, start : U64, len : U64 } -> List(U8)
	url_result = |{ token, start: from, len }| [19].concat("blob:spec/${token.to_str()}/${from.to_str()}/${len.to_str()}".to_utf8())

	## The pending digest that step `op` answers, when `op` is a `run-effect`
	## on one: its request id and the bytes to digest. The `spec` command
	## digests them through its host (`Io.sha256!`); a range over the
	## runtime's default `maxFileBytes` is answered TooLarge unread, as the
	## runtime answers it.
	digest_of : S(state), Scm.Op -> Try({ id : U32, bytes : [Digest(List(U8)), TooLarge] }, [NoDigest])
	digest_of = |s, op|
		match op {
			RunEffect(n) => {
				b = s.browser
				id = b.issued.get(n - 1) ? |_| NoDigest
				p = b.pending.find_first(|q| q.id == id) ? |_| NoDigest
				match p.kind {
					DigestRequest(file) => Ok({ id, bytes: if (file.len > SpecRunner.max_digest_bytes) TooLarge else Digest(SpecRunner.file_bytes(b, file)) })
					_ => Err(NoDigest)
				}
			}
			_ => Err(NoDigest)
		}

	## Deliver a digest's result payload (tag 18 and the digest, or tag 13
	## with reason 2) to request `id`.
	deliver_digest : Program(state), S(state), U32, List(U8) -> S(state)
	deliver_digest = |program, s, id, payload| {
		b = s.browser
		SpecRunner.deliver(program, { ..s, browser: { ..b, pending: b.pending.keep_if(|q| q.id != id) } }, id, payload)
	}

	## The pending worker job that step `op` runs, when `op` is a `run-effect`
	## on one. The `spec` command runs such a job in a child process
	## (`Io.work!`) and hands the result to `deliver_job`; every other step,
	## and every step a fuzz target or soak walk takes, goes through `one`.
	job_of : S(state), Scm.Op -> Try(Job, [NoJob])
	job_of = |s, op|
		match op {
			RunEffect(n) => {
				b = s.browser
				id = b.issued.get(n - 1) ? |_| NoJob
				p = b.pending.find_first(|q| q.id == id) ? |_| NoJob
				match p.kind {
					WorkRequest({ program: name, input, files, .. }) => Ok({ id, payload: SpecRunner.put_str([], name).concat(input), files: SpecRunner.job_files(b, files) })
					_ => Err(NoJob)
				}
			}
			_ => Err(NoJob)
		}

	## Deliver the result payload of job `job` (Appendix B: tag 10 with the
	## output, or tag 11 with a fault class). An empty result is a job that
	## did not finish within the runner's bound, which fails the step: a
	## spec's time is manual, and a job's deadline expires only when the spec
	## says so.
	deliver_job : Program(state), S(state), Job, List(U8) -> Try(S(state), Str)
	deliver_job = |program, s, job, result| {
		if result.is_empty() {
			return Err("the worker job did not finish within 30 s; a spec expires a job's deadline with time-out-work")
		}
		b = s.browser
		Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: b.pending.keep_if(|q| q.id != job.id) } }, job.id, result))
	}

	## `run-effect N`: a timer fires; a worker job runs its program in process
	## through the program's `work` entry, as a worker instance of the same
	## module would, and delivers `Work(output)` (a crash in the program ends
	## the process: fuzz targets and soak walks run jobs here, where that is a
	## finding); an HTTP request takes the staged answer.
	run_effect : Program(state), S(state), U64 -> Try(S(state), Str)
	run_effect = |program, s, n| {
		b = s.browser
		id = b.issued.get(n - 1) ? |_| "effect occurrence ${n.to_str()} was never issued (${b.issued.len().to_str()} issued)"
		p = b.pending.find_first(|q| q.id == id) ? |_| "effect occurrence ${n.to_str()} is not pending (cancelled or done)"
		rest = b.pending.keep_if(|q| q.id != id)
		match p.kind {
			TimerRequest => return Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: rest } }, id, [5]))
			WorkRequest({ program: name, input, files, .. }) => {
				output = (program.work)(SpecRunner.put_str([], name).concat(input), SpecRunner.job_files(b, files))
				return SpecRunner.deliver_job(program, s, { id, payload: [], files: [] }, [10].concat(output))
			}
			ReadRequest({ mode, file, max_bytes }) => return Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: rest } }, id, SpecRunner.read_result(b, mode, file, max_bytes)))
			UrlRequest(file) => return Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: rest } }, id, SpecRunner.url_result(file)))
			DigestRequest(_) => return Err("run-effect ${n.to_str()} answers a digest, which the spec command's host computes; fuzz targets and soak walks do not have one")
			PortRequest({ port, .. }) => return Err("effect occurrence ${n.to_str()} is a call on port ${JsonOut.quote(port)}; answer it with answer-port")
			HttpRequest => {}
			UploadRequest(_) => {}
		}
		stub = match b.stub {
			Staged(st) => st
			NoStub => return Err("run-effect ${n.to_str()} answers ${p.url} without a staged stub")
		}
		payload = match stub {
			Reply({ url, status, headers, body }) => {
				if url != p.url {
					return Err("no spec stub for ${p.url} (stub is for ${url})")
				}
				SpecRunner.encode_http(status, if (headers.is_empty()) [{ name: "content-type", value: "application/json" }] else headers, body)
			}
			Reject({ kind, detail }) => SpecRunner.encode_reject(kind, detail)
		}
		Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, stub: NoStub, pending: rest } }, id, payload))
	}

	## Fire one tick of every live interval of period `ms`.
	tick : Program(state), S(state), U64 -> S(state)
	tick = |program, s, ms| SpecRunner.broadcast(program, s, |x| x.sub == Interval(ms.to_u32_wrap()), [5])

	live_intervals : S(state), U64 -> U64
	live_intervals = |s, ms| s.browser.subs.count_if(|x| x.sub == Interval(ms.to_u32_wrap()))

	# ---------------------------------------------------------------- focus

	## A boolean attribute (`disabled`, `hidden`, ...) is present for any value
	## other than "" and "false", as the runtime sets it.
	flag_on : Dom.DNode, Str -> Bool
	flag_on = |n, name| {
		v = Dom.attr_of(n, name)
		v != "" and v != "false"
	}

	disabled : Dom.DNode -> Bool
	disabled = |n| SpecRunner.flag_on(n, "disabled")

	## Whether Chrome focuses node `n` when it is clicked or `.focus()`ed.
	focusable : Dom.DNode -> Bool
	focusable = |n| {
		tag_ok = n.tag == "button" or n.tag == "input" or n.tag == "select" or n.tag == "textarea" or (n.tag == "a" and Dom.attr_of(n, "href") != "") or Dom.attr_of(n, "tabindex") != ""
		tag_ok and !SpecRunner.disabled(n)
	}

	## The node a press on node `i` focuses (index + 1): the nearest focusable
	## element at or above it, or 0 (focus leaves the focused element).
	focus_target : Dom.Model, U64 -> U64
	focus_target = |dom, i| {
		n = Dom.node(dom, i)
		if SpecRunner.focusable(n) {
			i + 1
		} else if n.parent == 0 {
			0
		} else {
			SpecRunner.focus_target(dom, n.parent - 1)
		}
	}

	## A control whose edits fire `change` when it loses focus.
	text_control : Dom.DNode -> Bool
	text_control = |n| n.tag == "textarea" or (n.tag == "input" and SpecRunner.fillable.contains(Dom.attr_of(n, "type")))

	## The input types `fill` types into, as Playwright's `fill` allows.
	fillable : List(Str)
	fillable = ["", "text", "password", "email", "search", "tel", "url", "number"]

	## Move focus to node index `to` (+1; 0 blurs). The control losing focus
	## first gets `change` if the user changed its value since it gained focus,
	## then a value held back on it lands (the runtime applies it in a
	## capturing listener), then it gets `blur`, and the element gaining focus
	## gets `focus`; each event carries the element's value and is delivered
	## only when a handler listens. Nothing happens when focus stays.
	move_focus : Program(state), S(state), U64 -> S(state)
	move_focus = |program, s0, to| {
		if s0.focused == to {
			s0
		} else {
			from = s0.focused
			changed = if from != 0 and SpecRunner.text_control(Dom.node(s0.dom, from - 1)) {
				shown = Dom.attr_of(Dom.node(s0.dom, from - 1), "value")
				if (shown != s0.focus_value) SpecRunner.fire_if(program, s0, from - 1, "change", shown) else s0
			} else {
				s0
			}
			landed = match changed.deferred {
				Held(v) if from != 0 => SpecRunner.set_attr(changed, from - 1, "value", v)
				_ => changed
			}
			s1 = { ..landed, focused: to, deferred: NoValue, focus_value: if (to == 0) "" else Dom.attr_of(Dom.node(landed.dom, to - 1), "value") }
			s2 = if (from == 0) s1 else SpecRunner.fire_if(program, s1, from - 1, "blur", Dom.attr_of(Dom.node(s1.dom, from - 1), "value"))
			if (to == 0) s2 else SpecRunner.fire_if(program, s2, to - 1, "focus", Dom.attr_of(Dom.node(s2.dom, to - 1), "value"))
		}
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

	## The element a locator names (a `text` locator names the element holding
	## the text node).
	find : Dom.Model, Scm.Loc -> Try(U64, [NotFound])
	find = |dom, loc| {
		i = Dom.find(dom, dom.root, |n| SpecRunner.matches(dom, n, loc))?
		n = Dom.node(dom, i)
		if (n.tag == "" and n.parent != 0) Ok(n.parent - 1) else Ok(i)
	}

	need : Dom.Model, Scm.Loc -> Try(U64, Str)
	need = |dom, loc| SpecRunner.find(dom, loc).map_err(|_| "no element ${Scm.show_loc(loc)}")

	bool_str : Bool -> Str
	bool_str = |b| if (b) "true" else "false"

	set_attr : S(state), U64, Str, Str -> S(state)
	set_attr = |s, i, name, v| { ..s, dom: Dom.set_attr_on(s.dom, i, name, v) }

	## A control's live value: a `<select>` shows the value only when one of
	## its options has it.
	value_of : Dom.Model, U64 -> Str
	value_of = |dom, i| {
		n = Dom.node(dom, i)
		v = Dom.attr_of(n, "value")
		if n.tag == "select" and Dom.find(dom, i, |o| o.tag == "option" and Dom.attr_of(o, "value") == v).is_err() {
			""
		} else {
			v
		}
	}

	## What `expect-attr` reads, as the browser runner reads it: `checked` and
	## `disabled` as "true"/"false" from the live state, `value` as the live
	## value, a boolean attribute as "" when present, `class` as set, and any
	## other attribute as set unless the engine set it to "" (which removes it).
	attr_value : Dom.Model, U64, Str -> Try(Str, [Absent])
	attr_value = |dom, i, name| {
		n = Dom.node(dom, i)
		raw = Dom.attr_of(n, name)
		if name == "checked" {
			Ok(SpecRunner.bool_str(raw == "true"))
		} else if name == "disabled" {
			Ok(SpecRunner.bool_str(SpecRunner.disabled(n)))
		} else if name == "value" {
			Ok(SpecRunner.value_of(dom, i))
		} else if SpecRunner.bool_attrs.contains(name) {
			if (SpecRunner.flag_on(n, name)) Ok("") else Err(Absent)
		} else if name == "class" {
			if (n.attrs.any(|(k, _)| k == "class")) Ok(raw) else Err(Absent)
		} else if raw == "" {
			Err(Absent)
		} else {
			Ok(raw)
		}
	}

	## The attributes the runtime treats as boolean (design.md, Appendix B).
	bool_attrs : List(Str)
	bool_attrs = ["selected", "readonly", "required", "hidden", "multiple", "open"]

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

	## The engine's per-opcode work counters, and its issued and cancelled
	## effect counters, agree with the commands the oracle decoded from every
	## batch so far.
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
		# Every issued request is one FX command and every cancelled one a
		# CANCEL (design.md, "Counters"), so the effect counters must agree
		# with the commands too.
		for (counter, op, what) in [(32.U64, 13.U64, "issued"), (36, 14, "cancelled"), (40, 19, "port commands sent")] {
			engine = s.work.counters.get(counter) ?? 0
			oracle = s.ops.get(op) ?? 0
			if engine != oracle {
				return Err("the engine counted ${engine.to_str()} effects ${what} but emitted ${oracle.to_str()} ${Dom.op_name(op.to_u8_wrap())} commands")
			}
		}
		Ok({})
	}

	## The settle check after a step: the engine's pass over every layer must
	## emit nothing, or the step left a reader stale. The diagnostic names the
	## commands that pass emitted and the first element they would change, as
	## the oracle renders it now and after them.
	check_settled : Program(state), S(state) -> Try({}, Str)
	check_settled = |program, s| match (program.settled)(s.inst) {
		Ok(_) => Ok({})
		Err({ cmds, note }) => {
			r = Dom.apply_full(s.dom, cmds)
			first = match r.written.first() {
				Ok(i) => {
					n = Dom.node(r.dom, i)
					el = if (n.tag == "" and n.parent != 0) n.parent - 1 else i
					was = if (el < s.dom.nodes.len()) Dom.render(s.dom, el) else "(new)"
					"; first write: ${was} -> ${Dom.render(r.dom, el)}${SpecRunner.landmark(r.dom, el)}"
				}
				Err(_) => if (r.fx.is_empty()) "" else "; first effect: ${Str.inspect(r.fx.first() ?? crash "not empty")}"
			}
			effects = if (note.is_empty()) "" else "; effect channel: ${note}"
			Err("a reader was left stale: a settle pass over every layer emitted ${Dom.describe(r.ops)}${first}${effects}")
		}
	}

	## The nearest element at or above node `i` that a spec could locate by
	## `data-testid` or `aria-label`, for diagnostics ("" when none).
	landmark : Dom.Model, U64 -> Str
	landmark = |dom, i| {
		var $at = i + 1
		while $at != 0 {
			n = Dom.node(dom, $at - 1)
			tid = Dom.attr_of(n, "data-testid")
			label = Dom.attr_of(n, "aria-label")
			if tid != "" {
				return " (in test-id \"${tid}\")"
			}
			if label != "" {
				return " (in label \"${label}\")"
			}
			$at = n.parent
		}
		""
	}

	## Run one step; `Err` is the step's failure. Every step of the grammar
	## has a case here (the match has no catch-all).
	one : Program(state), S(state), Scm.Op -> Try(S(state), Str)
	one = |program, s, op| {
		dom = s.dom
		b = s.browser
		check = |ok, msg| if (ok) Ok(s) else Err(msg)
		match op {
			Click(loc) => {
				i = SpecRunner.need(dom, loc)?
				# A browser delivers no click to a disabled control.
				if (SpecRunner.disabled(Dom.node(dom, i))) Ok(s) else SpecRunner.mouse_click(program, s, i)
			}
			RealClick(loc) => {
				i = SpecRunner.need(dom, loc)?
				if (SpecRunner.disabled(Dom.node(dom, i))) Err("${Scm.show_loc(loc)} is disabled") else SpecRunner.mouse_click(program, s, i)
			}
			Fill(loc, v) => SpecRunner.fill(program, s, loc, v)
			ChooseFiles(_, names) => SpecRunner.give_files(program, s, op, SpecRunner.plain_handles(s, names.len()))
			DropFiles(_, names) => SpecRunner.give_files(program, s, op, SpecRunner.plain_handles(s, names.len()))
			PasteFiles(_, names) => SpecRunner.give_files(program, s, op, SpecRunner.plain_handles(s, names.len()))
			ExpectFiles(_) => Err("expect-files counts the handles live in the host; the spec command runs it, through its host")
			Focus(loc) => {
				i = SpecRunner.need(dom, loc)?
				if (SpecRunner.focusable(Dom.node(dom, i))) Ok(SpecRunner.move_focus(program, s, i + 1)) else Ok(s)
			}
			Blur(loc) => {
				i = SpecRunner.need(dom, loc)?
				if (s.focused == i + 1) Ok(SpecRunner.move_focus(program, s, 0)) else Ok(s)
			}
			Check(loc) => SpecRunner.set_checked(program, s, loc, Bool.True)
			Uncheck(loc) => SpecRunner.set_checked(program, s, loc, Bool.False)
			SelectOption(loc, v) => {
				i = SpecRunner.need(dom, loc)?
				n = Dom.node(dom, i)
				if n.tag != "select" {
					return Err("${Scm.show_loc(loc)} is not a <select>")
				}
				if Dom.find(dom, i, |o| o.tag == "option" and Dom.attr_of(o, "value") == v).is_err() {
					return Err("${Scm.show_loc(loc)} has no option ${JsonOut.quote(v)}")
				}
				s1 = SpecRunner.fire_if(program, SpecRunner.set_attr(s, i, "value", v), i, "input", v)
				Ok(SpecRunner.fire_if(program, s1, i, "change", v))
			}
			Change(loc, v) => {
				i = SpecRunner.need(dom, loc)?
				n = Dom.node(dom, i)
				kind = Dom.attr_of(n, "type")
				if n.tag == "input" and (kind == "radio" or kind == "checkbox") {
					if Dom.attr_of(n, "value") != v {
						return Err("${Scm.show_loc(loc)} has value ${JsonOut.quote(Dom.attr_of(n, "value"))}, not ${JsonOut.quote(v)}")
					}
					Ok(SpecRunner.fire_if(program, SpecRunner.check_on(s, i), i, "change", "true"))
				} else {
					Ok(SpecRunner.fire_if(program, SpecRunner.set_attr(s, i, "value", v), i, "change", v))
				}
			}
			Submit(loc) => {
				i = SpecRunner.need(dom, loc)?
				if Dom.node(dom, i).tag != "form" {
					return Err("${Scm.show_loc(loc)} is not a <form>")
				}
				Ok(SpecRunner.submit_form(program, s, i))
			}
			ExpectText(loc, want) => {
				got = Dom.text_of(dom, SpecRunner.need(dom, loc)?)
				check(got == want, "${Scm.show_loc(loc)} text ${JsonOut.quote(got)}, expected ${JsonOut.quote(want)}")
			}
			ExpectValue(loc, want) => {
				got = SpecRunner.value_of(dom, SpecRunner.need(dom, loc)?)
				check(got == want, "${Scm.show_loc(loc)} value ${JsonOut.quote(got)}, expected ${JsonOut.quote(want)}")
			}
			ExpectChecked(loc, want) => {
				got = Dom.attr_of(Dom.node(dom, SpecRunner.need(dom, loc)?), "checked") == "true"
				check(got == want, "${Scm.show_loc(loc)} checked ${SpecRunner.bool_str(got)}, expected ${SpecRunner.bool_str(want)}")
			}
			ExpectDisabled(loc, want) => {
				got = SpecRunner.disabled(Dom.node(dom, SpecRunner.need(dom, loc)?))
				check(got == want, "${Scm.show_loc(loc)} disabled ${SpecRunner.bool_str(got)}, expected ${SpecRunner.bool_str(want)}")
			}
			ExpectVisible(loc) => {
				_ = SpecRunner.need(dom, loc)?
				Ok(s)
			}
			ExpectAbsent(loc) => check(SpecRunner.find(dom, loc).is_err(), "${Scm.show_loc(loc)} is present")
			ExpectAttr({ target, name, value }) =>
				match SpecRunner.attr_value(dom, SpecRunner.need(dom, target)?, name) {
					Ok(got) => check(got == value, "${Scm.show_loc(target)} ${name}=${JsonOut.quote(got)}, expected ${JsonOut.quote(value)}")
					Err(Absent) => Err("${Scm.show_loc(target)} has no ${name} attribute, expected ${JsonOut.quote(value)}")
				}
			ExpectNoAttr({ target, name }) =>
				match SpecRunner.attr_value(dom, SpecRunner.need(dom, target)?, name) {
					Ok(got) => Err("${Scm.show_loc(target)} has ${name}=${JsonOut.quote(got)}")
					Err(Absent) => Ok(s)
				}
			ExpectUpdates(loc, n) => {
				i = SpecRunner.need(dom, loc)?
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
			RunEffect(n) => SpecRunner.run_effect(program, s, n)
			LoseWork({ occurrence, fault }) => {
				job = SpecRunner.pending_job(s, occurrence)?
				SpecRunner.deliver_job(program, s, { id: job.id, payload: [], files: [] }, SpecRunner.encode_lost(fault))
			}
			TimeOutWork(n) => {
				job = SpecRunner.pending_job(s, n)?
				if job.deadline_ms == 0 {
					return Err("worker job ${n.to_str()} has no deadline, so it cannot time out")
				}
				SpecRunner.deliver_job(program, s, { id: job.id, payload: [], files: [] }, [7])
			}
			ExpectPendingWork({ program: name, count }) => {
				got = b.pending.count_if(
					|q|
						match q.kind {
							WorkRequest(w) => w.program == name
							_ => Bool.False
						},
				)
				check(got == count, "expected ${count.to_str()} pending worker jobs for ${JsonOut.quote(name)}, got ${got.to_str()}")
			}
			StubHttp({ stub, .. }) =>
				match b.stub {
					NoStub => Ok({ ..s, browser: { ..b, stub: Staged(stub) } })
					Staged(_) => Err("a stub is already staged; run-effect answers one at a time")
				}
			Navigate(url) => SpecRunner.navigate(program, s, url)
			HistoryBack =>
				match b.back.last() {
					Ok(prev) if prev.doc != b.doc => Err("history-back crosses documents, which specs do not model")
					Ok(prev) => Ok(SpecRunner.popstate(program, { ..s, browser: { ..b, back: b.back.drop_last(1), fwd: [{ url: b.loc, doc: b.doc }].concat(b.fwd), loc: prev.url } }))
					Err(_) => Err("history-back with no history")
				}
			HistoryForward =>
				match b.fwd.first() {
					Ok(next) if next.doc != b.doc => Err("history-forward crosses documents, which specs do not model")
					Ok(next) => Ok(SpecRunner.popstate(program, { ..s, browser: { ..b, fwd: b.fwd.drop_first(1), back: b.back.append({ url: b.loc, doc: b.doc }), loc: next.url } }))
					Err(_) => Err("history-forward with no forward entry")
				}
			TickInterval(ms) =>
				if SpecRunner.live_intervals(s, ms) == 0 {
					Err("no live interval with period ${ms.to_str()} ms")
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
				got = SpecRunner.metric_delta(s, metric)?
				check(got == delta, "${metric} changed by ${got.to_str()}, expected ${delta.to_str()}")
			}
			ExpectMetricDeltaAtMost({ metric, delta }) => {
				got = SpecRunner.metric_delta(s, metric)?
				check(got <= delta, "${metric} changed by ${got.to_str()}, expected at most ${delta.to_str()}")
			}
			ExpectUpload({ occurrence, file, start: from, len }) => {
				id = b.issued.get(occurrence - 1) ? |_| "effect occurrence ${occurrence.to_str()} was never issued (${b.issued.len().to_str()} issued)"
				p = b.pending.find_first(|q| q.id == id) ? |_| "effect occurrence ${occurrence.to_str()} is not pending (cancelled or done)"
				body = match p.kind {
					UploadRequest(r) => r
					_ => return Err("effect occurrence ${occurrence.to_str()} is not an upload")
				}
				name = (b.given.find_first(|g| g.token == body.token) ?? { token: body.token, name: "" }).name
				check(name == file and body.start == from and body.len == len, "upload ${occurrence.to_str()} sends ${JsonOut.quote(name)} ${body.start.to_str()}+${body.len.to_str()}, expected ${JsonOut.quote(file)} ${from.to_str()}+${len.to_str()}")
			}
			ExpectPortCall({ occurrence, port, json }) => {
				call = SpecRunner.pending_port_call(s, occurrence)?
				check(call.port == port and call.json == json, "effect occurrence ${occurrence.to_str()} is a call on port ${JsonOut.quote(call.port)} with ${JsonOut.quote(call.json)}, expected port ${JsonOut.quote(port)} with ${JsonOut.quote(json)}")
			}
			AnswerPort({ occurrence, answer }) => {
				call = SpecRunner.pending_port_call(s, occurrence)?
				payload = match answer {
					Reply(json) => SpecRunner.encode_port_reply(json)
					Throw(message) => [15, 1].concat(message.to_utf8())
					TooLarge => [15, 2]
					Timeout =>
						if call.timeout_ms == 0 {
							return Err("the call on port ${JsonOut.quote(call.port)} has no timeout, so it cannot time out")
						} else {
							[7]
						}
				}
				Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: b.pending.keep_if(|q| q.id != call.id) } }, call.id, payload))
			}
			ExpectPortSent({ port, index, json }) => {
				sent = b.port_log.keep_if(|c| c.port == port)
				match sent.get(index - 1) {
					Ok(c) => check(c.json == json, "command ${index.to_str()} on port ${JsonOut.quote(port)} carried ${JsonOut.quote(c.json)}, expected ${JsonOut.quote(json)}")
					Err(_) => Err("port ${JsonOut.quote(port)} was sent ${sent.len().to_str()} commands, so there is no command ${index.to_str()}")
				}
			}
			ExpectPortSends({ port, count }) => {
				got = b.port_log.count_if(|c| c.port == port)
				check(got == count, "port ${JsonOut.quote(port)} was sent ${got.to_str()} commands, expected ${count.to_str()}")
			}
			EmitPort({ port, json }) =>
				if SpecRunner.port_subscriptions(s, port) == 0 {
					Err("no live subscription on port ${JsonOut.quote(port)}")
				} else {
					Ok(SpecRunner.broadcast(program, s, |x| SpecRunner.on_port(x.sub, port), SpecRunner.encode_port_reply(json)))
				}
			ClosePort(port) => SpecRunner.end_port(program, s, port, [15, 3])
			FailPort({ port, message }) => SpecRunner.end_port(program, s, port, [15, 1].concat(message.to_utf8()))
			ExpectPortSubscriptions({ port, count }) => {
				got = SpecRunner.port_subscriptions(s, port)
				check(got == count, "${got.to_str()} live subscriptions on port ${JsonOut.quote(port)}, expected ${count.to_str()}")
			}
		}
	}

	## The pending port call that is the N-th effect occurrence.
	pending_port_call : S(state), U64 -> Try({ id : U32, port : Str, json : Str, timeout_ms : U32 }, Str)
	pending_port_call = |s, n| {
		b = s.browser
		id = b.issued.get(n - 1) ? |_| "effect occurrence ${n.to_str()} was never issued (${b.issued.len().to_str()} issued)"
		p = b.pending.find_first(|q| q.id == id) ? |_| "effect occurrence ${n.to_str()} is not pending (cancelled or done)"
		match p.kind {
			PortRequest({ port, json, timeout_ms }) => Ok({ id, port, json, timeout_ms })
			_ => Err("effect occurrence ${n.to_str()} is not a port call")
		}
	}

	## A port reply's payload (result tag 14) carrying `json` and no bytes
	## or files.
	encode_port_reply : Str -> List(U8)
	encode_port_reply = |json| SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_str([14], json), 0), 0)

	on_port : Sub, Str -> Bool
	on_port = |sub, port| match sub {
		PortSub(p, _) => p == port
		_ => Bool.False
	}

	port_subscriptions : S(state), Str -> U64
	port_subscriptions = |s, port| s.browser.subs.count_if(|x| SpecRunner.on_port(x.sub, port))

	## The JavaScript ends every live subscription on `port` with the
	## terminal `payload`: each leaves the browser's live set, as the runtime
	## forgets it, and receives it as its last turn.
	end_port : Program(state), S(state), Str, List(U8) -> Try(S(state), Str)
	end_port = |program, s, port, payload| {
		b = s.browser
		ending = b.subs.keep_if(|x| SpecRunner.on_port(x.sub, port))
		if ending.is_empty() {
			return Err("no live subscription on port ${JsonOut.quote(port)}")
		}
		var $s = { ..s, browser: { ..b, subs: b.subs.keep_if(|x| !SpecRunner.on_port(x.sub, port)) } }
		for x in ending {
			$s = SpecRunner.deliver(program, $s, x.id, payload)
		}
		Ok($s)
	}

	## `fill`, as Playwright's: the control must be an enabled text input or
	## textarea that can hold the value (an `<input type=number>` holds only a
	## valid floating-point number or ""). Focus moves to it, and the whole
	## value arrives as one `input` event; filling an empty control with ""
	## deletes nothing and sends none.
	fill : Program(state), S(state), Scm.Loc, Str -> Try(S(state), Str)
	fill = |program, s, loc, v| {
		i = SpecRunner.need(s.dom, loc)?
		n = Dom.node(s.dom, i)
		kind = Dom.attr_of(n, "type")
		if !(n.tag == "textarea" or (n.tag == "input" and SpecRunner.fillable.contains(kind))) {
			return Err("${Scm.show_loc(loc)} cannot be filled")
		}
		if SpecRunner.disabled(n) {
			return Err("${Scm.show_loc(loc)} is disabled")
		}
		if kind == "number" and v != "" and !SpecRunner.is_float(v) {
			return Err("${Scm.show_loc(loc)} cannot hold ${JsonOut.quote(v)}")
		}
		s1 = SpecRunner.move_focus(program, s, i + 1)
		if v == "" and Dom.attr_of(Dom.node(s1.dom, i), "value") == "" {
			return Ok(s1)
		}
		# An input that echoes the held value makes it moot.
		s2 = if (s1.deferred == Held(v)) { ..s1, deferred: NoValue } else s1
		Ok(SpecRunner.fire_if(program, SpecRunner.set_attr(s2, i, "value", v), i, "input", v))
	}

	## A valid floating-point number (HTML): `-? (D+ (. D+)? | . D+) ([eE] [+-]? D+)?`.
	is_float : Str -> Bool
	is_float = |v| {
		digits = |bs| !bs.is_empty() and bs.all(|c| c >= '0' and c <= '9')
		bytes = v.to_utf8()
		body = if (bytes.first() == Ok('-')) bytes.drop_first(1) else bytes
		(mantissa, exponent) = match body.find_first_index(|c| c == 'e' or c == 'E') {
			Ok(k) => (body.sublist({ start: 0, len: k }), Ok(body.drop_first(k + 1)))
			Err(_) => (body, Err(None))
		}
		mantissa_ok = match mantissa.find_first_index(|c| c == '.') {
			Ok(k) => {
				whole = mantissa.sublist({ start: 0, len: k })
				frac = mantissa.drop_first(k + 1)
				digits(frac) and (whole.is_empty() or digits(whole))
			}
			Err(_) => digits(mantissa)
		}
		exponent_ok = match exponent {
			Ok(e) => digits(if (e.first() == Ok('+') or e.first() == Ok('-')) e.drop_first(1) else e)
			Err(_) => Bool.True
		}
		mantissa_ok and exponent_ok
	}

	## `check`/`uncheck`: a click on a checkbox or radio that is not in the
	## wanted state, which must then be in it.
	set_checked : Program(state), S(state), Scm.Loc, Bool -> Try(S(state), Str)
	set_checked = |program, s, loc, want| {
		i = SpecRunner.need(s.dom, loc)?
		n = Dom.node(s.dom, i)
		kind = if (n.tag == "input") Dom.attr_of(n, "type") else ""
		if kind != "checkbox" and kind != "radio" {
			return Err("${Scm.show_loc(loc)} is not a checkbox or radio button")
		}
		if kind == "radio" and !want {
			return Err("${Scm.show_loc(loc)} is a radio button, which cannot be unchecked")
		}
		if (Dom.attr_of(n, "checked") == "true") == want {
			return Ok(s)
		}
		s1 = if (SpecRunner.disabled(n)) s else SpecRunner.mouse_click(program, s, i)?
		now = SpecRunner.find(s1.dom, loc).map_ok(|k| Dom.attr_of(Dom.node(s1.dom, k), "checked") == "true") ?? !want
		if (now == want) Ok(s1) else Err("clicking ${Scm.show_loc(loc)} did not ${if (want) "check" else "uncheck"} it")
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

	## A real mouse click on node `i`, in Chrome's order: `mousedown`, then
	## focus moves (the default action of the press), then `mouseup` and
	## `click`, then the click's default action unless the dispatched click
	## handler prevented it (design.md, "The `.scm` spec language").
	mouse_click : Program(state), S(state), U64 -> Try(S(state), Str)
	mouse_click = |program, s0, i| {
		s1 = SpecRunner.fire_if(program, s0, i, "mousedown", "")
		s2 = SpecRunner.move_focus(program, s1, SpecRunner.focus_target(s1.dom, i))
		s3 = SpecRunner.fire_if(program, s2, i, "mouseup", "")
		prevented = Dom.prevents(s3.dom, i, "click")
		s4 = SpecRunner.fire_if(program, s3, i, "click", "")
		if (prevented) Ok(s4) else SpecRunner.default_action(program, s4, i)
	}

	## The browser's default action for a click on node `i`: a checkbox
	## toggles and a radio checks (each with `input` then `change`), a submit
	## button submits its form, and a link navigates.
	default_action : Program(state), S(state), U64 -> Try(S(state), Str)
	default_action = |program, s, i| {
		n = Dom.node(s.dom, i)
		kind = Dom.attr_of(n, "type")
		on_value = if (Dom.attr_of(n, "value") == "") "on" else Dom.attr_of(n, "value")
		if n.tag == "input" and kind == "checkbox" {
			want = Dom.attr_of(n, "checked") != "true"
			s1 = SpecRunner.fire_if(program, SpecRunner.set_attr(s, i, "checked", SpecRunner.bool_str(want)), i, "input", on_value)
			Ok(SpecRunner.fire_if(program, s1, i, "change", SpecRunner.bool_str(want)))
		} else if n.tag == "input" and kind == "radio" {
			if Dom.attr_of(n, "checked") == "true" {
				Ok(s)
			} else {
				s1 = SpecRunner.fire_if(program, SpecRunner.check_on(s, i), i, "input", on_value)
				Ok(SpecRunner.fire_if(program, s1, i, "change", "true"))
			}
		} else if (n.tag == "button" and (kind == "" or kind == "submit")) or (n.tag == "input" and kind == "submit") {
			match SpecRunner.ancestor(s.dom, i, |m| m.tag == "form") {
				Ok(form) => Ok(SpecRunner.submit_form(program, s, form))
				Err(_) => Ok(s)
			}
		} else {
			match SpecRunner.ancestor(s.dom, i, |m| m.tag == "a" and Dom.attr_of(m, "href") != "") {
				Ok(a) => {
					href = Dom.attr_of(Dom.node(s.dom, a), "href")
					url = SpecRunner.resolve(s.browser.loc, href) ? |_| "the click navigates to ${href}, which leaves the app"
					SpecRunner.navigate(program, s, url)
				}
				Err(_) => Ok(s)
			}
		}
	}

	## The nearest node at or above node `i` that satisfies `pred`.
	ancestor : Dom.Model, U64, (Dom.DNode -> Bool) -> Try(U64, [NotFound])
	ancestor = |dom, i, pred| {
		n = Dom.node(dom, i)
		if pred(n) {
			Ok(i)
		} else if n.parent == 0 {
			Err(NotFound)
		} else {
			SpecRunner.ancestor(dom, n.parent - 1, pred)
		}
	}

	## Submit form `i` as `requestSubmit` does: a form whose controls are not
	## all valid fires no `submit`.
	submit_form : Program(state), S(state), U64 -> S(state)
	submit_form = |program, s, i| if (SpecRunner.form_valid(s.dom, i)) SpecRunner.fire_if(program, s, i, "submit", "") else s

	## Constraint validation over the enabled controls inside form `i`: a
	## `required` control must have a value (a checkbox must be checked), an
	## email field a valid address, and a number field a value within its
	## `min` and `max`.
	form_valid : Dom.Model, U64 -> Bool
	form_valid = |dom, i| Dom.find(dom, i, |n| SpecRunner.invalid(n)).is_err()

	invalid : Dom.DNode -> Bool
	invalid = |n| {
		control = n.tag == "input" or n.tag == "textarea" or n.tag == "select"
		if !control or SpecRunner.disabled(n) {
			Bool.False
		} else {
			kind = Dom.attr_of(n, "type")
			v = Dom.attr_of(n, "value")
			missing = if (kind == "checkbox" or kind == "radio") Dom.attr_of(n, "checked") != "true" else v == ""
			bound = |name, out_of_range|
				match (F64.from_str(Dom.attr_of(n, name)), F64.from_str(v)) {
					(Ok(limit), Ok(x)) => out_of_range(x, limit)
					_ => Bool.False
				}
			(SpecRunner.flag_on(n, "required") and missing)
				or (kind == "email" and v != "" and !SpecRunner.is_email(v))
				or (kind == "number" and v != "" and (bound("min", |x, m| x < m) or bound("max", |x, m| x > m)))
		}
	}

	## A valid e-mail address (HTML): a local part of letters, digits and
	## ``.!#$%&'*+/=?^_`{|}~-``, `@`, and dot-separated labels of letters,
	## digits and inner hyphens.
	is_email : Str -> Bool
	is_email = |v|
		match v.split_on("@") {
			[local, domain] => {
				local_ok = !local.is_empty() and local.to_utf8().all(|c| SpecRunner.alnum(c) or ".!#$%&'*+/=?^_`{|}~-".to_utf8().contains(c))
				label_ok = |l| {
					bs = l.to_utf8()
					!bs.is_empty() and bs.len() <= 63 and bs.all(|c| SpecRunner.alnum(c) or c == '-') and bs.first() != Ok('-') and bs.last() != Ok('-')
				}
				local_ok and domain.split_on(".").all(label_ok)
			}
			_ => Bool.False
		}

	alnum : U8 -> Bool
	alnum = |c| (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')

	## `url` resolved against `base`, both path-absolute: a fragment, a query or
	## an absolute path; a relative path resolves against `base`'s directory.
	## A URL with a scheme or an authority leaves the app.
	resolve : Str, Str -> Try(Str, [External])
	resolve = |base, url| {
		path_q = SpecRunner.before(base, "#")
		path = SpecRunner.before(path_q, "?")
		if url.contains("://") or url.starts_with("//") {
			Err(External)
		} else if url.starts_with("#") {
			Ok("${path_q}${url}")
		} else if url.starts_with("?") {
			Ok("${path}${url}")
		} else if url.starts_with("/") {
			Ok(url)
		} else {
			dir = match path.split_on("/").drop_last(1) {
				[] => ""
				parts => Str.join_with(parts, "/")
			}
			Ok("${dir}/${url}")
		}
	}

	## A history URL the app pushed or replaced: it stays in the document.
	resolve_in_document : Str, Str -> Str
	resolve_in_document = |base, url| SpecRunner.resolve(base, url) ?? crash "contract: the app pushed ${url}, which leaves the app"

	## The part of `s` before the first `sep`.
	before : Str, Str -> Str
	before = |s, sep| s.split_on(sep).first() ?? s

	## The HTML same-document rule: `to` has a fragment and differs from
	## `from` only in it.
	same_document : Str, Str -> Bool
	same_document = |from, to| to.contains("#") and SpecRunner.before(from, "#") == SpecRunner.before(to, "#")

	## Navigate to `url` as a user would: within the document, a new history
	## entry and a popstate; otherwise the app mounts afresh at `url` in a new
	## document, with the same local storage, connectivity and visibility.
	navigate : Program(state), S(state), Str -> Try(S(state), Str)
	navigate = |program, s, url| {
		b = s.browser
		entry = { url: b.loc, doc: b.doc }
		if SpecRunner.same_document(b.loc, url) {
			Ok(SpecRunner.popstate(program, { ..s, browser: { ..b, back: b.back.append(entry), loc: url, fwd: [] } }))
		} else {
			s1 = SpecRunner.mount_in(program, { url, storage: b.storage, online: b.online, visible: b.visible, storage_available: b.storage_available })
			b1 = s1.browser
			Ok({ ..s1, mark: s.mark, browser: { ..b1, doc: b.doc + 1, back: b.back.append(entry), fwd: [], files: b.files, given: b.given } })
		}
	}

	## Handles for `n` files when no host mints them (`one`, for fuzz targets
	## and soak walks): plain boxes, so their release is not observed.
	plain_handles : S(state), U64 -> List(Box(U64))
	plain_handles = |s, n| {
		base = 0x1000000000000000 + s.browser.given.len()
		var $out = []
		var $i = 0
		while $i < n {
			$out = $out.append(Box.box(base + $i))
			$i = $i + 1
		}
		$out
	}

	## How many files a file step gives the app.
	file_count : Scm.Op -> Try(U64, [NoFiles])
	file_count = |op|
		match op {
			ChooseFiles(_, names) => Ok(names.len())
			DropFiles(_, names) => Ok(names.len())
			PasteFiles(_, names) => Ok(names.len())
			_ => Err(NoFiles)
		}

	## `choose-files`, `drop-files` and `paste-files`: the user gives the app
	## the named setup files, as the browser's `change` on a file input,
	## `drop` or `paste` event (design.md, "Files"). `handles` are the
	## handles the host minted, as many as it had room for; the rest are
	## refused, as the record says. The located element (or, for a drop or a
	## paste, an ancestor) must have a `:files` handler for the event, and a
	## file input must take as many files as are chosen.
	give_files : Program(state), S(state), Scm.Op, List(Box(U64)) -> Try(S(state), Str)
	give_files = |program, s, op, handles| {
		(loc, ev, names) = match op {
			ChooseFiles(l, n) => (l, "change", n)
			DropFiles(l, n) => (l, "drop", n)
			PasteFiles(l, n) => (l, "paste", n)
			_ => return Err("not a file step")
		}
		dom = s.dom
		i = SpecRunner.need(dom, loc)?
		n = Dom.node(dom, i)
		if ev == "change" {
			if n.tag != "input" or Dom.attr_of(n, "type") != "file" {
				return Err("${Scm.show_loc(loc)} is not a file input")
			}
			if SpecRunner.disabled(n) {
				return Err("${Scm.show_loc(loc)} is disabled")
			}
			if names.len() > 1 and Dom.attr_of(n, "multiple") == "" {
				return Err("${Scm.show_loc(loc)} takes one file, not ${names.len().to_str()}")
			}
		}
		(node, h) = Dom.files_target(dom, i, ev) ? |_| "no ${ev} handler that takes files at ${Scm.show_loc(loc)}"
		var $files = []
		for name in names {
			f = s.browser.files.find_first(|g| g.name == name) ? |_| "no setup file named \"${name}\""
			$files = $files.append(f)
		}
		minted = handles.len()
		var $record = SpecRunner.put_u32(SpecRunner.put_u32([], minted.to_u32_wrap()), (names.len() - minted).to_u32_wrap())
		var $given = s.browser.given
		var $k = 0
		for handle in handles {
			f = $files.get($k) ?? crash "SpecRunner.give_files: more handles than files"
			$record = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u64($record, f.bytes.len()), f.name), f.mime)
			$given = $given.append({ token: Box.unbox(handle), name: f.name })
			$k = $k + 1
		}
		b = s.browser
		s1 = { ..s, browser: { ..b, given: $given } }
		(inst, cmds, wbuf) = (program.files)(s1.inst, s1.buf, s1.wbuf, node, h, $record, handles)
		Ok(SpecRunner.answer_gets(program, SpecRunner.take(s1, inst, cmds, wbuf)))
	}

	## The host services a replay uses: running a worker job in a child
	## process, and minting and counting file handles in the host's heap.
	Host : { work! : List(U8), List(List(U8)) => List(U8), mint_files! : U64 => List(Box(U64)), live_files! : () => U64, sha256! : List(U8) => List(U8) }

	## Replay one spec from a fresh mount, running each worker job with
	## `work!` (the `spec` command's child process, `Io.work!`), and giving
	## the app files through handles the host mints (`Io.mint_files!`).
	run! : Program(state), Host, Scm.Spec => Outcome
	run! = |program, host, spec| {
		var $s = match SpecRunner.start(program, spec) {
			Ok(s) => s
			Err(message) => return Failed({ step: 0, at: spec.steps.first() ?? crash "a parsed spec has steps", message })
		}
		match SpecRunner.check_settled(program, $s) {
			Ok(_) => {}
			Err(message) => return Failed({ step: 0, at: spec.steps.first() ?? crash "a parsed spec has steps", message: "after mount, ${message}" })
		}
		var $i = 0.U64
		for step in spec.steps {
			# Every step, a worker job's answer and a file handed over
			# included, must also leave the engine settled: an oracle on the
			# engine, not a step, so the browser runner has no equivalent.
			done = match (SpecRunner.job_of($s, step.op), SpecRunner.file_count(step.op), step.op) {
				(Ok(job), _, _) => SpecRunner.deliver_job(program, $s, job, (host.work!)(job.payload, job.files))
				(_, Ok(n), _) => SpecRunner.give_files(program, $s, step.op, (host.mint_files!)(n))
				(_, _, ExpectFiles(n)) => {
					live = (host.live_files!)()
					if (live == n) Ok($s) else Err("expected ${n.to_str()} live file handles, found ${live.to_str()}")
				}
				_ =>
					match SpecRunner.digest_of($s, step.op) {
						Ok({ id, bytes: Digest(bytes) }) => Ok(SpecRunner.deliver_digest(program, $s, id, [18].concat((host.sha256!)(bytes))))
						Ok({ id, bytes: TooLarge }) => Ok(SpecRunner.deliver_digest(program, $s, id, [13, 2]))
						Err(NoDigest) => SpecRunner.one(program, $s, step.op)
					}
			}
			match done {
				Ok(s2) => {
					match SpecRunner.check_settled(program, s2) {
						Ok(_) => {}
						Err(message) => return Failed({ step: $i, at: step, message })
					}
					$s = s2
				}
				Err(message) => return Failed({ step: $i, at: step, message })
			}
			$i = $i + 1
		}
		Passed
	}

	# ------------------------------------------------------------------ CLI

	## The host services the `spec` command uses, passed in by the test
	## program (the test platform's `Cli`), so this package stays pure.
	Io : { read_file! : Str => List(U8), stdout! : Str => {}, stderr! : Str => {}, now_ns! : () => U64, work! : List(U8), List(List(U8)) => List(U8), mint_files! : U64 => List(Box(U64)), live_files! : () => U64, sha256! : List(U8) => List(U8) }

	Options : { filter : Str, emit_steps : Bool, grammar : Bool, files : List(Str) }

	usage : Str
	usage = "usage: RUNNER [--filter GLOB] [--emit-steps] FILE.scm...\n       RUNNER --grammar\n"

	parse_args : List(Str) -> Try(Options, Str)
	parse_args = |args| {
		var $o = { filter: "*", emit_steps: Bool.False, grammar: Bool.False, files: [] }
		var $i = 0.U64
		while $i < args.len() {
			a = args.get($i) ?? ""
			if a == "--filter" {
				$o = { ..$o, filter: args.get($i + 1) ? |_| "--filter needs a pattern" }
				$i = $i + 2
			} else if a == "--emit-steps" {
				$o = { ..$o, emit_steps: Bool.True }
				$i = $i + 1
			} else if a == "--grammar" {
				$o = { ..$o, grammar: Bool.True }
				$i = $i + 1
			} else if a.starts_with("--") {
				return Err("unknown option ${a}")
			} else {
				$o = { ..$o, files: $o.files.append(a) }
				$i = $i + 1
			}
		}
		if $o.grammar {
			if ($o.files.is_empty() and !$o.emit_steps) Ok($o) else Err("--grammar takes no other arguments")
		} else if $o.files.is_empty() {
			Err("no spec files given")
		} else {
			Ok($o)
		}
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
	## `spec-result` JSON line per spec. Exit 0 when nothing failed. `--grammar`
	## prints the grammar's form names instead (`Scm.grammar_json`), for the
	## browser runner's `--check-grammar`.
	main! : Program(state), Io, List(Str) => I32
	main! = |program, io, args| {
		opts = match SpecRunner.parse_args(args) {
			Ok(o) => o
			Err(msg) => {
				(io.stderr!)("${msg}\n${SpecRunner.usage}")
				return 2
			}
		}
		if opts.grammar {
			(io.stdout!)("${JsonOut.render(Scm.grammar_json)}\n")
			return 0
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
						outcome = SpecRunner.run!(program, { work!: io.work!, mint_files!: io.mint_files!, live_files!: io.live_files!, sha256!: io.sha256! }, spec)
						dt = (io.now_ns!)() - t0
						line = match outcome {
							Passed => {
								$counts = { ..$counts, passed: $counts.passed + 1 }
								SpecRunner.result_line({ id, name: spec.name, status: "passed", duration_ns: dt, failure: Null })
							}
							Failed({ step, at, message }) => {
								$counts = { ..$counts, failed: $counts.failed + 1 }
								full = "${path}:${at.pos.line.to_str()}:${at.pos.column.to_str()}: ${Scm.op_name(at.op)}: ${message}"
								SpecRunner.result_line({ id, name: spec.name, status: "failed", duration_ns: dt, failure: SpecRunner.failure_json("step", "assertion", full, step, at.pos) })
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
	o = SpecRunner.parse_args(["--filter", "a*", "x.scm"]) ?? { filter: "", emit_steps: Bool.False, grammar: Bool.False, files: [] }
	o.filter == "a*" and o.files == ["x.scm"] and SpecRunner.parse_args(["--pending-phase3", "x.scm"]).is_err() and SpecRunner.parse_args([]).is_err() and SpecRunner.parse_args(["--grammar"]).is_ok() and SpecRunner.parse_args(["--grammar", "x.scm"]).is_err()
}

## Same-document navigations differ only in a fragment; relative URLs resolve
## against the current path.
expect {
	actual = [
		SpecRunner.same_document("/a/#/x", "/a/#/y"),
		SpecRunner.same_document("/a/#/x", "/a/"),
		SpecRunner.same_document("/a/", "/b/#x"),
		SpecRunner.resolve("/a/b?q#h", "#t") == Ok("/a/b?q#t"),
		SpecRunner.resolve("/a/b?q#h", "?r") == Ok("/a/b?r"),
		SpecRunner.resolve("/a/b", "c") == Ok("/a/c"),
		SpecRunner.resolve("/a/b", "https://example.test/") == Err(External),
	]
	actual == [Bool.True, Bool.False, Bool.False, Bool.True, Bool.True, Bool.True, Bool.True]
}

## Number inputs hold HTML's valid floating-point numbers only; email fields
## want one @ and well-formed labels.
expect {
	actual = ["2", "-2.5", ".5", "1e3", "2x", "1.", "+2", "-"].map(SpecRunner.is_float).concat(["a@b", "a.b@c.d", "a@", "@b", "a@b..c", "a@-b"].map(SpecRunner.is_email))
	actual == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.False, Bool.False, Bool.False, Bool.True, Bool.True, Bool.False, Bool.False, Bool.False, Bool.False]
}

## A lost job carries its fault class as the runtime numbers it.
expect [AppCrash, Unavailable, Executor].map(SpecRunner.encode_lost) == [[11, 4], [11, 6], [11, 7]]
