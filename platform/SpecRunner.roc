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
##   fires, a worker job runs its task (the `spec` command runs it in a
##   child process, `Io.work!`, which serves the job's hosted effects, so a
##   crash loses only the job, as in a worker; the same runs a walk's
##   jobs, `--walk`),
##   and an HTTP request takes the staged answer, whose URL must be the
##   request's (a
##   reject answers any). Storage reads answer by themselves, from storage, in
##   the turn after the call that issued them.
## - A rejected request becomes `Timeout`, or `Network(detail)`.
## - A spec's time is manual: a worker job's timeout expires only through
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
## - A click delivers `pointermove`, `mousemove`, `pointerdown`, `mousedown`,
##   focus moves to the nearest focusable element (or away), `pointerup`,
##   `mouseup`, `click`, then the default action
##   unless the dispatched click handler prevented it: a checkbox toggles, a
##   radio checks (each with `input` and `change`), a submit button submits
##   its form if the form's controls are valid, and a link navigates. A prevented
##   `pointerdown` suppresses `mousedown`, `mouseup` and the focus change.
##   Hover boundary events are outside the spec language.
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

		## An event carrying files: its file record and the handles minted for it.
		files : state, List(U8), List(U8), U32, U32, List(U8), List(Box(U64)) -> (state, List(U8), List(U8)),

		## The engine's settle check (`Core.settled`): `Err` holds the
		## commands a pass over every layer emitted on a discarded copy.
		settled : state -> Try({}, { cmds : List(U8), note : Str }),

		## The engine's requests in flight, in issue order (`Core.fx_live`):
		## a soak's replay finds the request a recorded answer goes to by its
		## place among them.
		live : state -> List(U32),
	}

	Sub : [Interval(U32), Pop, OnlineSub, VisibilitySub, PortSub(Str, Str)]

	## A history entry: its URL and the document it belongs to.
	Entry : { url : Str, doc : U64 }

	## An awaited request still waiting for `run-effect`: an HTTP request (its
	## URL and body), a timer, or a worker job (its task and input).
	Pending : { id : U32, url : Str, body : Str, kind : PendingKind }

	## What `run-effect` does for a pending request.
	PendingKind : [
		HttpRequest,
		TimerRequest,

		## A worker job, as its request describes it. The `spec` command runs
		## it in a child process (`Io.work!`), which serves its hosted
		## effects.
		WorkRequest(Dom.WorkJob),

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

		## An HTTP request whose body becomes a file (`File.fetch`):
		## `run-effect` answers it with the staged stub, its body as the
		## file, through a handle the host mints.
		FetchRequest,
	]

	## The most bytes a digest or a page read reads: the runtime's default
	## `maxFileBytes`.
	max_digest_bytes : U64
	max_digest_bytes = 256 * 1024 * 1024

	## The most bytes a job appends to its builders when a spec does not
	## say: the runtime's default `maxOutputBytes` (design.md, "Workers").
	max_output_bytes : U64
	max_output_bytes = 256 * 1024 * 1024

	## The most bytes a fetched body may hold: the runtime's default
	## `maxFileBytes`.
	max_fetch_bytes : U64
	max_fetch_bytes = 256 * 1024 * 1024

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

		## The files the app saved in this document (`SAVE`), in order: the
		## name and the bytes of the range, read when the batch was applied.
		saves : List({ name : Str, bytes : List(U8) }),

		## The most bytes a task's job may append to its builders (the
		## `max-output-bytes` setup, else the runtime's default).
		max_output : U64,
	}

	## A setup file: its name, media type and contents.
	SetupFile : { name : Str, mime : Str, bytes : List(U8) }

	## The runner's state: the instance and the buffers it lends back, the
	## oracle's DOM and browser models, the latest work record, the oracle's
	## own opcode counts, per-node write counts (`expect-updates`), the work
	## counters at the last `mark-metrics`, the focused node (index + 1, 0
	## for none) and the value it showed when it gained focus, and the value
	## the engine wrote to the focused control that the controlled-input rule
	## holds back until blur. Focus effects and their queued browser events
	## share one iterative drain, bounded at 4096 events waiting and 4096
	## turns delivered before returning to idle.
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
		focus_commands : List({ mode : U8, node : U32 }),
		event_queue : List({ node : U32, handler : U32, payload : List(U8), owner : U64 }),
		applying_focus : Bool,
		draining : Bool,
		turns : U64,
		fault : [Healthy, Poisoned(Str)],
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

	## A `u64` at `at` of a record the runner's own host wrote; a
	## truncated one is the host's bug.
	get_u64 : List(U8), U64 -> U64
	get_u64 = |b, at| {
		lo = SpecRunner.get_u32(b, at) ?? crash "SpecRunner.get_u64: a host record is truncated"
		hi = SpecRunner.get_u32(b, at + 4) ?? crash "SpecRunner.get_u64: a host record is truncated"
		lo.to_u64() + hi.to_u64().shl_wrap(32)
	}

	## A string (`len:u32 bytes`) at `at` of a record the runner's own host
	## wrote, and where it ends.
	get_str : List(U8), U64 -> (Str, U64)
	get_str = |b, at| {
		len = (SpecRunner.get_u32(b, at) ?? crash "SpecRunner.get_str: a host record is truncated").to_u64()
		text = Str.from_utf8(b.sublist({ start: at + 4, len })) ?? crash "SpecRunner.get_str: a host record's text is not UTF-8"
		(text, at + 4 + len)
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

	## A worker job's result payload for an answer that holds no files: tag
	## 10, a file count of zero, then the answer's bytes as a job's entry
	## gives them after its file list. Fuzz models of the effect channel
	## answer jobs through this, so the framing
	## has one place (design.md, Appendix B, result tag 10).
	encode_answer : List(U8) -> List(U8)
	encode_answer = |answer| SpecRunner.put_u32([10], 0).concat(answer)

	## The pending worker job that is the N-th effect occurrence, for
	## `lose-work` and `time-out-work`.
	pending_job : S(state), U64 -> Try({ id : U32, timeout_ms : U32 }, Str)
	pending_job = |s, n| {
		b = s.browser
		id = b.issued.get(n - 1) ? |_| "effect occurrence ${n.to_str()} was never issued (${b.issued.len().to_str()} issued)"
		p = b.pending.find_first(|q| q.id == id) ? |_| "effect occurrence ${n.to_str()} is not pending (cancelled or done)"
		match p.kind {
			WorkRequest({ timeout_ms, .. }) => Ok({ id, timeout_ms })
			FetchRequest => Err("effect occurrence ${n.to_str()} is a fetch, not a worker job")
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
		focused = if (s.focused != 0 and !SpecRunner.attached(r.dom, s.focused - 1)) 0 else s.focused
		held = SpecRunner.hold_focused({ ..s, focused }, r.dom, r.values)
		{
			..s,
			inst,
			buf: cmds,
			dom: held.dom,
			focused,
			deferred: held.deferred,
			browser: SpecRunner.absorb(s.browser, r.fx),
			focus_commands: s.focus_commands.concat(
				r.fx.keep_oks(
					|fx| match fx {
						Focus(mode, node) => Ok({ mode, node })
						_ => Err(NotFocus)
					},
				),
			),
			ops: $ops,
			writes: $w,
		}
	}

	## Whether a model node still belongs to the mounted document. Removing a
	## focused subtree clears focus without raising blur, as the browser does.
	attached : Dom.Model, U64 -> Bool
	attached = |dom, i| {
		var $at = i
		while $at != dom.root {
			parent = Dom.node(dom, $at).parent
			if parent == 0 {
				return Bool.False
			}
			$at = parent - 1
		}
		Bool.True
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
		shown = Dom.live_value(Dom.node(s.dom, i), "value")
		var $deferred = s.deferred
		var $wrote = Bool.False
		for (node, v) in values {
			if node == i {
				$wrote = Bool.True
				$deferred = if (v == shown) NoValue else Held(v)
			}
		}
		if $wrote {
			{ dom: Dom.set_live_on(dom, i, "value", shown), deferred: $deferred }
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
		saves: [],
		max_output: SpecRunner.max_output_bytes,
	}

	## A runner state for instance `inst` before its first batch.
	fresh : state, Browser -> S(state)
	fresh = |inst, browser| { inst, buf: [], wbuf: [], dom: Dom.new({}), browser, work: { counters: [], cleanups: [] }, ops: List.repeat(0, 23), writes: [], mark: [], focused: 0, focus_value: "", deferred: NoValue, focus_commands: [], event_queue: [], applying_focus: Bool.False, draining: Bool.False, turns: 0, fault: Healthy }

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
				Work(id, job) => { ..b, pending: b.pending.append({ id, url: "work", body: "", kind: WorkRequest(job) }), issued: b.issued.append(id) }
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
				Fetch(id, _, url, _, _) => { ..b, pending: b.pending.append({ id, url, body: "", kind: FetchRequest }), issued: b.issued.append(id) }
				# The runtime resolves a save's file when it applies the batch,
				# while a handle the batch released still names its file.
				Save(file, name) => { ..b, saves: b.saves.append({ name, bytes: SpecRunner.file_bytes(b, file) }) }
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
		var $max_output = SpecRunner.max_output_bytes
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
				MaxOutputBytes(n) => {
					$max_output = n
				}
			}
		}
		if !$storage_available and !$storage.is_empty() {
			return Err("local-storage seeds storage that local-storage-unavailable says the app cannot read")
		}
		s0 = SpecRunner.mount_in(program, { url: $url, storage: $storage, online: $online, visible: $visible, storage_available: $storage_available })
		b0 = s0.browser
		Ok({ ..s0, browser: { ..b0, files: $files, max_output: $max_output } })
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
		{ ..SpecRunner.drain_focus(program, SpecRunner.answer_gets(program, SpecRunner.take({ ..s0, draining: Bool.True }, inst, cmds, wbuf))), draining: Bool.False }
	}

	## Dispatch event `ev` with `payload` from DOM node index `i`, as the
	## runtime's delegated listener does.
	fire : Program(state), S(state), U64, Str, Str -> Try(S(state), Str)
	fire = |program, s, i, ev, payload|
		match Dom.target(s.dom, i, ev, Bool.True) {
			Err(_) => Err("no ${ev} handler")
			Ok(target) => if (target.kind == 1) Ok(SpecRunner.send(program, s, target.node, target.handler, payload.to_utf8())) else Ok(s)
		}

	## Dispatch `ev` if a handler listens for it on the way up from node `i`.
	fire_if : Program(state), S(state), U64, Str, Str -> S(state)
	fire_if = |program, s, i, ev, payload| SpecRunner.fire(program, s, i, ev, payload) ?? s

	## One host call, then the storage reads and focus events it issued, each
	## answered in a turn of its own as the runtime answers them. Reentrant
	## focus callbacks wait until all of their batch's effects have landed.
	send : Program(state), S(state), U32, U32, List(U8) -> S(state)
	send = |program, s, node, h, payload| {
		if s.fault != Healthy {
			return s
		}
		if s.applying_focus {
			if s.event_queue.len() >= 4096 {
				return { ..s, fault: Poisoned("resource_limit: more than 4096 events queued behind one batch (an event feedback loop)"), event_queue: [], focus_commands: [] }
			}
			return { ..s, event_queue: s.event_queue.append({ node, handler: h, payload, owner: Dom.lookup(s.dom, node) }) }
		}
		outer = !s.draining
		active = if (outer) { ..s, draining: Bool.True, turns: 0 } else s
		if !outer and active.turns >= 4096 {
			return { ..active, fault: Poisoned("resource_limit: more than 4096 turns delivered without returning to idle (an event feedback loop)"), event_queue: [], focus_commands: [] }
		}
		counted = { ..active, turns: active.turns + if (outer) 0 else 1 }
		(inst, cmds, wbuf) = (program.event)(counted.inst, counted.buf, counted.wbuf, node, h, payload)
		next = SpecRunner.answer_gets(program, SpecRunner.take(counted, inst, cmds, wbuf))
		if (outer) { ..SpecRunner.drain_focus(program, next), draining: Bool.False } else next
	}

	## Apply every focus command of a batch before delivering the events it
	## raises. Those events retain their routes and join the bounded ingress
	## queue, so two focus effects cannot observe a partly applied batch.
	drain_focus : Program(state), S(state) -> S(state)
	drain_focus = |program, s0| {
		var $s = { ..s0, draining: Bool.True }
		while $s.fault == Healthy and (!$s.focus_commands.is_empty() or !$s.event_queue.is_empty()) {
			while $s.fault == Healthy and !$s.focus_commands.is_empty() {
				command = $s.focus_commands.first() ?? crash "SpecRunner.drain_focus: not empty"
				s = { ..$s, applying_focus: Bool.True, focus_commands: $s.focus_commands.drop_first(1) }
				index1 = (s.dom.statics.get(command.node.to_u64()) ?? 0).bitwise_and(1099511627775)
				applied = if (index1 == 0) s else {
					i = index1 - 1
					if command.mode == 2 {
						if (s.focused == i + 1) SpecRunner.move_focus(program, s, 0) else s
					} else if SpecRunner.focusable_in(s.dom, i) {
						SpecRunner.move_focus(program, s, i + 1)
					} else s
				}
				$s = { ..applied, applying_focus: Bool.False }
			}
			match $s.event_queue.first() {
				Ok(event) => {
					pending = { ..$s, event_queue: $s.event_queue.drop_first(1) }
					current = (pending.dom.statics.get(event.node.to_u64()) ?? 0).bitwise_and(1099511627775)
					$s = if (current == event.owner + 1 and SpecRunner.attached(pending.dom, event.owner)) SpecRunner.send(program, pending, event.node, event.handler, event.payload) else pending
				}
				Err(_) => {}
			}
		}
		{ ..$s, draining: s0.draining }
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

	## Deliver result `payload` to the pending worker job `id` without
	## running it: a fault class (tag 11) or its timeout (tag 7).
	deliver_job : Program(state), S(state), U32, List(U8) -> Try(S(state), Str)
	deliver_job = |program, s, id, payload| {
		b = s.browser
		Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: b.pending.keep_if(|q| q.id != id) } }, id, payload))
	}

	## `run-effect N`: a timer fires; an HTTP request takes the staged answer.
	## A worker job runs only where the `spec` command's host can run it
	## (`step!`); fuzz targets that drive the engine answer one themselves.
	run_effect : Program(state), S(state), U64 -> Try(S(state), Str)
	run_effect = |program, s, n| {
		b = s.browser
		id = b.issued.get(n - 1) ? |_| "effect occurrence ${n.to_str()} was never issued (${b.issued.len().to_str()} issued)"
		p = b.pending.find_first(|q| q.id == id) ? |_| "effect occurrence ${n.to_str()} is not pending (cancelled or done)"
		rest = b.pending.keep_if(|q| q.id != id)
		match p.kind {
			TimerRequest => return Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: rest } }, id, [5]))
			WorkRequest(_) => return Err("run-effect ${n.to_str()} runs a worker job, which needs the spec command's host for its effects")
			ReadRequest({ mode, file, max_bytes }) => return Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: rest } }, id, SpecRunner.read_result(b, mode, file, max_bytes)))
			UrlRequest(file) => return Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: rest } }, id, SpecRunner.url_result(file)))
			DigestRequest(_) => return Err("run-effect ${n.to_str()} answers a digest, which the spec command's host computes")
			PortRequest({ port, .. }) => return Err("effect occurrence ${n.to_str()} is a call on port ${JsonOut.quote(port)}; answer it with answer-port")
			FetchRequest => return Err("run-effect ${n.to_str()} answers a fetch, whose body the spec command's host holds as a file")
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
		tag_ok = n.tag == "button" or n.tag == "input" or n.tag == "select" or n.tag == "textarea" or (n.tag == "a" and Dom.has_attr(n, "href")) or Dom.has_attr(n, "tabindex")
		tag_ok and !SpecRunner.disabled(n) and !SpecRunner.flag_on(n, "hidden") and !(n.tag == "input" and Dom.attr_of(n, "type") == "hidden")
	}

	## Focus cannot enter a detached or hidden subtree. The oracle checks
	## declared HTML attributes; CSS layout remains the browser's domain.
	focusable_in : Dom.Model, U64 -> Bool
	focusable_in = |dom, i| {
		if !SpecRunner.focusable(Dom.node(dom, i)) {
			return Bool.False
		}
		var $at = i
		while True {
			n = Dom.node(dom, $at)
			if SpecRunner.flag_on(n, "hidden") {
				return Bool.False
			}
			if $at == dom.root {
				return Bool.True
			}
			if n.parent == 0 {
				return Bool.False
			}
			$at = n.parent - 1
		}
	}

	## The node a press on node `i` focuses (index + 1): the nearest focusable
	## element at or above it, or 0 (focus leaves the focused element).
	focus_target : Dom.Model, U64 -> U64
	focus_target = |dom, i| {
		n = Dom.node(dom, i)
		if SpecRunner.focusable_in(dom, i) {
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
				shown = SpecRunner.value_of(s0.dom, from - 1)
				if (shown != s0.focus_value) SpecRunner.fire_if(program, s0, from - 1, "change", shown) else s0
			} else {
				s0
			}
			landed = match changed.deferred {
				Held(v) if from != 0 => SpecRunner.set_attr(changed, from - 1, "value", v)
				_ => changed
			}
			s1 = { ..landed, focused: to, deferred: NoValue, focus_value: if (to == 0) "" else SpecRunner.value_of(landed.dom, to - 1) }
			s2 = if (from == 0) s1 else SpecRunner.fire_if(program, s1, from - 1, "blur", SpecRunner.value_of(s1.dom, from - 1))
			if (to == 0) s2 else SpecRunner.fire_if(program, s2, to - 1, "focus", SpecRunner.value_of(s2.dom, to - 1))
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
			Label(x) => n.tag != "" and Dom.has_attr(n, "aria-label") and Dom.attr_of(n, "aria-label") == x
			TestId(x) => n.tag != "" and Dom.has_attr(n, "data-testid") and Dom.attr_of(n, "data-testid") == x
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
	set_attr = |s, i, name, v| { ..s, dom: if (name == "value" or name == "checked") Dom.set_live_on(s.dom, i, name, v) else Dom.set_attr_on(s.dom, i, name, v) }

	## A control's live value: a `<select>` shows the value only when one of
	## its options has it.
	value_of : Dom.Model, U64 -> Str
	value_of = |dom, i| {
		n = Dom.node(dom, i)
		v = Dom.live_value(n, "value")
		if n.tag == "option" {
			if (Dom.has_attr(n, "value")) Dom.attr_of(n, "value") else Dom.text_of(dom, i)
		} else if n.tag == "select" and !SpecRunner.has_option(dom, { root: i, value: v }) {
			""
		} else if n.tag == "input" and ["checkbox", "radio"].contains(Dom.attr_of(n, "type")) and !Dom.has_attr(n, "value") {
			"on"
		} else v
	}

	## Options whose value attribute is absent use their text. A present empty
	## value remains empty. Search only this select's descendants.
	has_option : Dom.Model, { root : U64, value : Str } -> Bool
	has_option = |dom, { root, value }| {
		n = Dom.node(dom, root)
		if n.tag == "option" and SpecRunner.value_of(dom, root) == value {
			return Bool.True
		}
		n.kids.any(|child| SpecRunner.has_option(dom, { root: child, value }))
	}

	## What `expect-attr` reads, as the browser runner reads it: `checked` and
	## `disabled` as "true"/"false" from the live state, `value` as the live
	## value, a boolean attribute as "" when present, `class` as set, and any
	## other attribute as set, including an explicitly present empty string.
	attr_value : Dom.Model, U64, Str -> Try(Str, [Absent])
	attr_value = |dom, i, name| {
		n = Dom.node(dom, i)
		raw = Dom.attr_of(n, name)
		if name == "checked" and n.tag == "input" {
			Ok(SpecRunner.bool_str(Dom.live_value(n, "checked") == "true"))
		} else if name == "disabled" {
			Ok(SpecRunner.bool_str(SpecRunner.disabled(n)))
		} else if name == "value" and ["input", "textarea", "select", "option"].contains(n.tag) {
			Ok(SpecRunner.value_of(dom, i))
		} else if SpecRunner.bool_attrs.contains(name) {
			if (SpecRunner.flag_on(n, name)) Ok("") else Err(Absent)
		} else if Dom.has_attr(n, name) {
			Ok(raw)
		} else Err(Absent)
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
		for (counter, op, what) in [(32.U64, 13.U64, "issued"), (36, 14, "cancelled"), (40, 19, "port commands sent"), (41, 21, "properties set"), (42, 22, "row properties set")] {
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
	check_settled = |program, s| {
		match s.fault {
			Poisoned(message) => return Err(message)
			Healthy => {}
		}
		match (program.settled)(s.inst) {
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
			ChooseFiles(_, _) | DropFiles(_, _) | PasteFiles(_, _) => SpecRunner.give_files(program, s, op, SpecRunner.plain_handles(s, SpecRunner.file_count(dom, op) ?? 0))
			ExpectFiles(_) => Err("expect-files counts the handles live in the host; the spec command runs it, through its host")
			Focus(loc) => {
				i = SpecRunner.need(dom, loc)?
				if (SpecRunner.focusable_in(dom, i)) Ok(SpecRunner.move_focus(program, s, i + 1)) else Ok(s)
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
				if !SpecRunner.has_option(dom, { root: i, value: v }) {
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
					if SpecRunner.value_of(dom, i) != v {
						return Err("${Scm.show_loc(loc)} has value ${JsonOut.quote(SpecRunner.value_of(dom, i))}, not ${JsonOut.quote(v)}")
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
			ExpectFocused(loc) => check(s.focused == SpecRunner.need(dom, loc)? + 1, "${Scm.show_loc(loc)} does not hold focus")
			ExpectNoFocus => check(s.focused == 0, "an element still holds focus")
			ExpectText(loc, want) => {
				got = Dom.text_of(dom, SpecRunner.need(dom, loc)?)
				check(got == want, "${Scm.show_loc(loc)} text ${JsonOut.quote(got)}, expected ${JsonOut.quote(want)}")
			}
			ExpectValue(loc, want) => {
				i = SpecRunner.need(dom, loc)?
				n = Dom.node(dom, i)
				if !["input", "textarea", "select", "option", "button"].contains(n.tag) and !n.props.any(|(key, _)| key == "value") {
					return Err("${Scm.show_loc(loc)} has no live value property")
				}
				got = SpecRunner.value_of(dom, i)
				check(got == want, "${Scm.show_loc(loc)} value ${JsonOut.quote(got)}, expected ${JsonOut.quote(want)}")
			}
			ExpectChecked(loc, want) => {
				got = Dom.live_value(Dom.node(dom, SpecRunner.need(dom, loc)?), "checked") == "true"
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
				SpecRunner.deliver_job(program, s, job.id, SpecRunner.encode_lost(fault))
			}
			TimeOutWork(n) => {
				job = SpecRunner.pending_job(s, n)?
				if job.timeout_ms == 0 {
					return Err("worker job ${n.to_str()} has no timeout, so it cannot time out")
				}
				SpecRunner.deliver_job(program, s, job.id, [7])
			}
			ExpectPendingWork({ task: name, count }) => {
				got = b.pending.count_if(
					|q|
						match q.kind {
							WorkRequest(w) => w.task == name
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
			ExpectSaved({ index, name, text }) =>
				match b.saves.get(index - 1) {
					Ok(saved) => {
						got = Str.from_utf8(saved.bytes) ?? "<${saved.bytes.len().to_str()} bytes that are not UTF-8>"
						check(saved.name == name and got == text, "save ${index.to_str()} was ${JsonOut.quote(saved.name)} holding ${JsonOut.quote(got)}, expected ${JsonOut.quote(name)} holding ${JsonOut.quote(text)}")
					}
					Err(_) => Err("the app saved ${b.saves.len().to_str()} files, so there is no save ${index.to_str()}")
				}
			ExpectSaves(n) => check(b.saves.len() == n, "the app saved ${b.saves.len().to_str()} files, expected ${n.to_str()}")
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

	## A port answer's payload (result tag 14) carrying `json` and no bytes
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
		if v == "" and Dom.live_value(Dom.node(s1.dom, i), "value") == "" {
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
		if (Dom.live_value(n, "checked") == "true") == want {
			return Ok(s)
		}
		s1 = if (SpecRunner.disabled(n)) s else SpecRunner.mouse_click(program, s, i)?
		now = SpecRunner.find(s1.dom, loc).map_ok(|k| Dom.live_value(Dom.node(s1.dom, k), "checked") == "true") ?? !want
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
				if $k != i and m.tag == "input" and Dom.attr_of(m, "type") == "radio" and Dom.attr_of(m, "name") == group and Dom.live_value(m, "checked") == "true" {
					$d = Dom.set_live_on($d, $k, "checked", "false")
				}
				$k = $k + 1
			}
			{ ..s, dom: $d }
		} else {
			s
		}
		SpecRunner.set_attr(s1, i, "checked", "true")
	}

	## Default prevention is read from the nearest declaration's policy bits;
	## a files drop also prevents by its payload kind's rule.
	prevents : Dom.Model, U64, Str -> Bool
	prevents = |dom, i, event| Dom.target(dom, i, event, Bool.True).map_ok(|target| target.policies.bitwise_and(1) != 0 or (target.kind == 2 and event == "drop")) ?? Bool.False

	## A click delivers Chrome's pointer and mouse sequence at the destination.
	## Preventing pointerdown suppresses compatibility mouse press/release and
	## its focus change; pointerup and click still arrive.
	mouse_click : Program(state), S(state), U64 -> Try(S(state), Str)
	mouse_click = |program, s0, i| {
		s1 = SpecRunner.fire_if(program, s0, i, "pointermove", "")
		s2 = SpecRunner.fire_if(program, s1, i, "mousemove", "")
		press_prevented = SpecRunner.prevents(s2.dom, i, "pointerdown")
		s3 = SpecRunner.fire_if(program, s2, i, "pointerdown", "")
		s4 = if (press_prevented) s3 else {
			mouse_prevented = SpecRunner.prevents(s3.dom, i, "mousedown")
			pressed = SpecRunner.fire_if(program, s3, i, "mousedown", "")
			if (mouse_prevented) pressed else SpecRunner.move_focus(program, pressed, SpecRunner.focus_target(pressed.dom, i))
		}
		s5 = SpecRunner.fire_if(program, s4, i, "pointerup", "")
		s6 = if (press_prevented) s5 else SpecRunner.fire_if(program, s5, i, "mouseup", "")
		prevented = SpecRunner.prevents(s6.dom, i, "click")
		s7 = SpecRunner.fire_if(program, s6, i, "click", "")
		if (prevented) Ok(s7) else SpecRunner.default_action(program, s7, i)
	}

	## The browser's default action for a click on node `i`: a checkbox
	## toggles and a radio checks (each with `input` then `change`), a submit
	## button submits its form, and a link navigates.
	default_action : Program(state), S(state), U64 -> Try(S(state), Str)
	default_action = |program, s, i| {
		match s.fault {
			Poisoned(message) => return Err(message)
			Healthy => {}
		}
		n = Dom.node(s.dom, i)
		kind = Dom.attr_of(n, "type")
		on_value = SpecRunner.value_of(s.dom, i)
		if n.tag == "input" and kind == "checkbox" {
			want = Dom.live_value(n, "checked") != "true"
			s1 = SpecRunner.fire_if(program, SpecRunner.set_attr(s, i, "checked", SpecRunner.bool_str(want)), i, "input", on_value)
			Ok(SpecRunner.fire_if(program, s1, i, "change", SpecRunner.bool_str(want)))
		} else if n.tag == "input" and kind == "radio" {
			if Dom.live_value(n, "checked") == "true" {
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
			match SpecRunner.ancestor(s.dom, i, |m| m.tag == "a" and Dom.has_attr(m, "href")) {
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
			v = Dom.live_value(n, "value")
			missing = if (kind == "checkbox" or kind == "radio") Dom.live_value(n, "checked") != "true" else v == ""
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
			Ok({ ..s1, mark: s.mark, browser: { ..b1, doc: b.doc + 1, back: b.back.append(entry), fwd: [], files: b.files, given: b.given, max_output: b.max_output } })
		}
	}

	## Handles for `n` files when no host mints them (`one`, for fuzz targets
	## that drive it without a host): plain boxes, so their release is not
	## observed.
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

	## Only a files declaration stages handles. A text declaration, or no
	## listener, leaves the selected browser files outside the Roc instance.
	file_count : Dom.Model, Scm.Op -> Try(U64, [NoFiles])
	file_count = |dom, op| {
		(loc, event, count) = match op {
			ChooseFiles(target, names) => (target, "change", names.len())
			DropFiles(target, names) => (target, "drop", names.len())
			PasteFiles(target, names) => (target, "paste", names.len())
			_ => return Err(NoFiles)
		}
		i = SpecRunner.find(dom, loc) ?? return Ok(0)
		declaration = Dom.target(dom, i, event, Bool.True) ?? return Ok(0)
		Ok(if (declaration.kind == 2) count else 0)
	}

	## `choose-files`, `drop-files` and `paste-files`: the user gives the app
	## the named setup files, as the browser's `change` on a file input,
	## `drop` or `paste` event (design.md, "Files"). `handles` are the
	## handles the host minted, as many as it had room for; the rest are
	## refused, as the record says. The located element (or, for a drop or a
	## paste, an ancestor) supplies the nearest declaration for the event, and a
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
			if !Dom.is_file_input(n) {
				return Err("${Scm.show_loc(loc)} is not a file input")
			}
			if SpecRunner.disabled(n) {
				return Err("${Scm.show_loc(loc)} is disabled")
			}
			if names.len() > 1 and Dom.attr_of(n, "multiple") == "" {
				return Err("${Scm.show_loc(loc)} takes one file, not ${names.len().to_str()}")
			}
		}
		var $files = []
		for name in names {
			f = s.browser.files.find_first(|g| g.name == name) ? |_| "no setup file named \"${name}\""
			$files = $files.append(f)
		}
		text = if ev == "change" {
			match names.first() {
				Ok(name) => "C:\\fakepath\\${name}"
				Err(_) => ""
			}
		} else ""
		selected = if (ev == "change") SpecRunner.set_attr(s, i, "value", text) else s
		target = match Dom.target(dom, i, ev, Bool.True) {
			Ok(declaration) => declaration
			Err(_) => return Ok(selected)
		}
		if target.kind == 1 {
			return Ok(SpecRunner.send(program, selected, target.node, target.handler, text.to_utf8()))
		}
		if names.is_empty() {
			return Ok(selected)
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
		b = selected.browser
		s1 = { ..selected, browser: { ..b, given: $given } }
		(inst, cmds, wbuf) = (program.files)(s1.inst, s1.buf, s1.wbuf, target.node, target.handler, $record, handles)
		Ok({ ..SpecRunner.drain_focus(program, SpecRunner.answer_gets(program, SpecRunner.take({ ..s1, draining: Bool.True, turns: 0 }, inst, cmds, wbuf))), draining: Bool.False })
	}

	## The pending worker job or fetch that step `op` answers, when `op` is
	## a `run-effect` on one: a job's request id, its payload and the whole
	## files its entries name, split as the runtime splits a preparation's
	## task into the preparation's call and the task's (`prepare` empty for
	## a task of its own), and its output bound; or a fetch's id and the
	## staged stub, which `run-effect` consumes. The `spec` command runs a
	## job in a child process (`Io.work!`) and mints a fetched body's handle
	## (`Io.mint_files!`); every other step goes through `one`.
	held_of : S(state), Scm.Op -> Try([WorkJob({ id : U32, payload : List(U8), files : List(List(U8)), prepare : List(U8), prepare_files : List(List(U8)), max_output : U64 }), FetchAnswer({ id : U32, stub : Scm.Stub })], Str)
	held_of = |s, op|
		match op {
			RunEffect(n) => {
				b = s.browser
				id = b.issued.get(n - 1) ? |_| "not held"
				p = b.pending.find_first(|q| q.id == id) ? |_| "not held"
				match p.kind {
					WorkRequest({ task: name, input, files, prepared, .. }) => {
						whole = files.map(|r| SpecRunner.whole_file(b, r.token))
						job = match prepared {
							Unprepared => { id, payload: SpecRunner.put_str([], name).concat(input), files: whole, prepare: [], prepare_files: [], max_output: b.max_output }
							Prepared({ name: prep, input_len, input_files }) => {
								id,
								payload: SpecRunner.put_str([], name).concat(input.drop_first(input_len)),
								files: whole.drop_first(input_files),
								prepare: SpecRunner.put_str([], prep).concat(input.take_first(input_len)),
								prepare_files: whole.take_first(input_files),
								max_output: b.max_output,
							}
						}
						Ok(WorkJob(job))
					}
					FetchRequest =>
						match b.stub {
							Staged(stub) => Ok(FetchAnswer({ id, stub }))
							NoStub => Err("run-effect ${n.to_str()} answers ${p.url} without a staged stub")
						}
					_ => Err("not held")
				}
			}
			_ => Err("not held")
		}

	## The bytes of the whole file a handle was given for: a job is sent the
	## file, not its range, and reads the range itself.
	whole_file : Browser, U64 -> List(U8)
	whole_file = |b, token| {
		name = (b.given.find_first(|g| g.token == token) ?? { token, name: "" }).name
		(b.files.find_first(|f| f.name == name) ?? { name, mime: "", bytes: [] }).bytes
	}

	## Deliver a job's answer from the runner's record of it (`Cli.work!`):
	## tag 10's files are minted as the page's handles (`handles`, which
	## `mint!` gave) and kept as files the runner can read back, named `#N`
	## beside the spec's own files, and the answer goes to the app through
	## the effect node with those handles, as the runtime delivers it. Tag 11
	## passes through. An empty record is a job that did not finish within
	## the runner's bound, which fails the step: a spec's time is manual, and
	## a job's timeout expires only when the spec says so. When the host had
	## too few slots, the answer is `WorkLost(ResourceLimit)` and the handles
	## it minted go unused, as the runtime does.
	deliver_work! : Program(state), S(state), U32, List(U8), (U64 => List(Box(U64))) => Try(S(state), Str)
	deliver_work! = |program, s, id, record, mint!| {
		b = s.browser
		rest = { ..s, browser: { ..b, pending: b.pending.keep_if(|q| q.id != id) } }
		match record {
			[] => Err("the worker job did not finish within 30 s; a spec expires a job's timeout with time-out-work")
			[10, ..] => {
				n = (SpecRunner.get_u32(record, 1) ?? 0).to_u64()
				var $at = 5.U64
				var $metas = []
				while $metas.len() < n {
					size = SpecRunner.get_u64(record, $at)
					(name, a1) = SpecRunner.get_str(record, $at + 8)
					(mime, a2) = SpecRunner.get_str(record, a1)
					$metas = $metas.append({ size, name, mime })
					$at = a2
				}
				out_len = SpecRunner.get_u64(record, $at)
				output = record.sublist({ start: $at + 8, len: out_len })
				$at = $at + 8 + out_len
				handles = mint!(n)
				if handles.len() < n {
					return Ok(SpecRunner.deliver(program, rest, id, [11, 2]))
				}
				var $payload = SpecRunner.put_u32([10], n.to_u32_wrap())
				var $files = rest.browser.files
				var $given = rest.browser.given
				var $k = 0
				for meta in $metas {
					handle = handles.get($k) ?? crash "SpecRunner.deliver_work!: minted"
					bytes = record.sublist({ start: $at, len: meta.size })
					$at = $at + meta.size
					key = "#${(rest.browser.files.len() + $k).to_str()}"
					$files = $files.append({ name: key, mime: meta.mime, bytes })
					$given = $given.append({ token: Box.unbox(handle), name: key })
					$payload = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u64($payload, meta.size), meta.name), meta.mime)
					$k = $k + 1
				}
				rb = rest.browser
				s1 = { ..rest, browser: { ..rb, files: $files, given: $given } }
				(inst, cmds, wbuf) = (program.files)(s1.inst, s1.buf, s1.wbuf, SpecRunner.fx_node, id, $payload.concat(output), handles)
				Ok({ ..SpecRunner.drain_focus(program, SpecRunner.answer_gets(program, SpecRunner.take({ ..s1, draining: Bool.True, turns: 0 }, inst, cmds, wbuf))), draining: Bool.False })
			}
			_ => Ok(SpecRunner.deliver(program, rest, id, record))
		}
	}

	## Answer a fetch with the staged stub (design.md, "Files"): an HTTP response's
	## body becomes a file the page holds, through a handle `mint!` gives,
	## delivered as result tag 21 with the status and headers; a reject is
	## `Timeout` or `Network` as for an HTTP request; a body over the
	## runtime's `maxFileBytes` is `FileFailed(TooLarge)`. The stub's URL
	## must be the request's.
	deliver_fetch! : Program(state), S(state), U32, Scm.Stub, (U64 => List(Box(U64))) => Try(S(state), Str)
	deliver_fetch! = |program, s, id, stub, mint!| {
		b = s.browser
		p = b.pending.find_first(|q| q.id == id) ? |_| "the fetch is not pending"
		rest = { ..s, browser: { ..b, stub: NoStub, pending: b.pending.keep_if(|q| q.id != id) } }
		match stub {
			Reject({ kind, detail }) => Ok(SpecRunner.deliver(program, rest, id, SpecRunner.encode_reject(kind, detail)))
			Reply({ url, status, headers: given, body }) => {
				if url != p.url {
					return Err("no spec stub for ${p.url} (stub is for ${url})")
				}
				# A stub without headers answers JSON, as for an HTTP request.
				headers = if (given.is_empty()) [{ name: "content-type", value: "application/json" }] else given
				bytes = body.to_utf8()
				if bytes.len() > SpecRunner.max_fetch_bytes {
					return Ok(SpecRunner.deliver(program, rest, id, [13, 2]))
				}
				handles = mint!(1)
				handle = handles.first() ? |_| "the host had no slot for the fetched file"
				mime = (headers.find_first(|h| h.name == "content-type") ?? { name: "", value: "" }).value
				name = SpecRunner.url_file_name(url)
				key = "#${b.files.len().to_str()}"
				var $record = SpecRunner.put_u32([21, status.bitwise_and(0xFF).to_u8_wrap(), status.shr_zf_wrap(8).to_u8_wrap()], headers.len().to_u32_wrap())
				for h in headers {
					$record = SpecRunner.put_str(SpecRunner.put_str($record, h.name), h.value)
				}
				record = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u64($record, bytes.len()), name), mime)
				rb = rest.browser
				s1 = { ..rest, browser: { ..rb, files: rb.files.append({ name: key, mime, bytes }), given: rb.given.append({ token: Box.unbox(handle), name: key }) } }
				(inst, cmds, wbuf) = (program.files)(s1.inst, s1.buf, s1.wbuf, SpecRunner.fx_node, id, record, handles)
				Ok({ ..SpecRunner.drain_focus(program, SpecRunner.answer_gets(program, SpecRunner.take({ ..s1, draining: Bool.True, turns: 0 }, inst, cmds, wbuf))), draining: Bool.False })
			}
		}
	}

	## The name a fetched body gets: the last segment of the URL's path,
	## without its query or fragment, or `download` when that is empty, as
	## the runtime names it.
	url_file_name : Str -> Str
	url_file_name = |url| {
		path = url.split_on("?").first() ?? url
		bare = path.split_on("#").first() ?? path
		last = bare.split_on("/").last() ?? ""
		if (last.is_empty()) "download" else last
	}

	## The host services a replay uses: running a worker job in a child
	## process, minting and counting file handles in the host's heap, and
	## digesting bytes.
	Host : { work! : List(U8), List(List(U8)), List(U8), List(List(U8)), U64 => List(U8), mint_files! : U64 => List(Box(U64)), live_files! : () => U64, sha256! : List(U8) => List(U8), live_allocations! : () => U64, live_bytes! : () => U64 }

	## Where a spec failed: the step's index, the step, and why.
	Failure : { step : U64, at : Scm.Step, message : Str }

	## Replay one spec from a fresh mount, running each worker job with
	## `work!` (the `spec` command's child process, `Io.work!`), and giving
	## the app files through handles the host mints (`Io.mint_files!`).
	run! : Program(state), Host, Scm.Spec => Outcome
	run! = |program, host, spec| match SpecRunner.drive!(program, host, spec, { begin: |s| s, after: |s, _| s }) {
		Ok(_) => Passed
		Err(failure) => Failed(failure)
	}

	## Drive one spec from a fresh mount, as `run!` does, and hand back the
	## runner's state after its last step. `begin` sees the state after the
	## mount and `after` the state after each step, once the step and its
	## settle check have passed.
	drive! : Program(state), Host, Scm.Spec, { begin : S(state) -> S(state), after : S(state), Scm.Op -> S(state) } => Try(S(state), Failure)
	drive! = |program, host, spec, { begin, after }| {
		var $s = match SpecRunner.start(program, spec) {
			Ok(s) => s
			Err(message) => return Err({ step: 0, at: spec.steps.first() ?? crash "a parsed spec has steps", message })
		}
		match SpecRunner.check_settled(program, $s) {
			Ok(_) => {}
			Err(message) => return Err({ step: 0, at: spec.steps.first() ?? crash "a parsed spec has steps", message: "after mount, ${message}" })
		}
		$s = begin($s)
		var $i = 0.U64
		for step in spec.steps {
			# Every step, a worker job's answer and a file handed over
			# included, must also leave the engine settled: an oracle on the
			# engine, not a step, so the browser runner has no equivalent.
			match SpecRunner.step!(program, host, $s, step.op) {
				Ok(s2) => {
					match SpecRunner.check_settled(program, s2) {
						Ok(_) => {}
						Err(message) => return Err({ step: $i, at: step, message })
					}
					$s = after(s2, step.op)
				}
				Err(message) => return Err({ step: $i, at: step, message })
			}
			$i = $i + 1
		}
		Ok($s)
	}

	## Take one step as the `spec` command takes it: the steps its host
	## serves (a worker job run in a child process, a fetched body or a
	## file given through handles it mints, a digest it computes, the live
	## handle count) through `host`, every other step through `one`.
	step! : Program(state), Host, S(state), Scm.Op => Try(S(state), Str)
	step! = |program, host, s, op|
		match (SpecRunner.file_count(s.dom, op), op) {
			(Ok(n), _) => SpecRunner.give_files(program, s, op, (host.mint_files!)(n))
			(_, ExpectFiles(n)) => {
				live = (host.live_files!)()
				if (live == n) Ok(s) else Err("expected ${n.to_str()} live file handles, found ${live.to_str()}")
			}
			_ =>
				match (SpecRunner.held_of(s, op), SpecRunner.digest_of(s, op)) {
					(Ok(WorkJob(job)), _) => SpecRunner.deliver_work!(program, s, job.id, (host.work!)(job.payload, job.files, job.prepare, job.prepare_files, job.max_output), host.mint_files!)
					(Ok(FetchAnswer({ id, stub })), _) => SpecRunner.deliver_fetch!(program, s, id, stub, host.mint_files!)
					(Err(message), _) if message != "not held" => Err(message)
					(_, Ok({ id, bytes: Digest(bytes) })) => Ok(SpecRunner.deliver_digest(program, s, id, [18].concat((host.sha256!)(bytes))))
					(_, Ok({ id, bytes: TooLarge })) => Ok(SpecRunner.deliver_digest(program, s, id, [13, 2]))
					(_, Err(NoDigest)) => SpecRunner.one(program, s, op)
				}
		}

	# ----------------------------------------------------------------- walks

	## What a walk answers the app's requests with, gathered from the app's
	## own specs, so the walk needs nothing written for it: every HTTP
	## response and rejection a spec stages (by URL), every port answer (by the
	## port a spec's `expect-port-call` names for that occurrence, else for
	## any port), every message a spec emits on a port, and every value a
	## spec types or changes into a control (by its locator).
	Book : {
		replies : List({ url : Str, stub : Scm.Stub }),
		rejects : List(Scm.Stub),
		port_answers : List({ port : Str, answer : Scm.PortAnswer }),
		loose_answers : List(Scm.PortAnswer),
		messages : List({ port : Str, json : Str }),
		typed : List({ loc : Scm.Loc, value : Str }),
	}

	## The book of a set of specs.
	book : List(Scm.Spec) -> Book
	book = |specs| {
		var $b = { replies: [], rejects: [], port_answers: [], loose_answers: [], messages: [], typed: [] }
		for spec in specs {
			for step in spec.steps {
				$b = match step.op {
					StubHttp({ stub: Reply(r), .. }) => { ..$b, replies: $b.replies.append({ url: r.url, stub: Reply(r) }) }
					StubHttp({ stub: Reject(r), .. }) => { ..$b, rejects: $b.rejects.append(Reject(r)) }
					AnswerPort({ occurrence, answer }) =>
						match SpecRunner.port_of_call(spec.steps, occurrence) {
							Ok(port) => { ..$b, port_answers: $b.port_answers.append({ port, answer }) }
							Err(_) => { ..$b, loose_answers: $b.loose_answers.append(answer) }
						}
					EmitPort(m) => { ..$b, messages: $b.messages.append(m) }
					Fill(loc, value) => { ..$b, typed: $b.typed.append({ loc, value }) }
					Change(loc, value) => { ..$b, typed: $b.typed.append({ loc, value }) }
					_ => $b
				}
			}
		}
		$b
	}

	## The port a spec's `expect-port-call` names for an occurrence.
	port_of_call : List(Scm.Step), U64 -> Try(Str, [Unnamed])
	port_of_call = |steps, occurrence| {
		for step in steps {
			match step.op {
				ExpectPortCall(c) if c.occurrence == occurrence => return Ok(c.port)
				_ => {}
			}
		}
		Err(Unnamed)
	}

	## Payloads a walk types into text boxes, beside those the specs type.
	pool : List(Str)
	pool = ["", "a", "Ada", "10", "-3", "2x", "x@y.z", "Lorem ipsum dolor", "Node-0007", "# Title", "Renamed"]

	## (node index, event name) for every attached node with a handler,
	## disabled controls skipped, in document order.
	candidates : Dom.Model -> List((U64, Str))
	candidates = |dom| {
		var $stack = [dom.root]
		var $out = []
		while !$stack.is_empty() {
			i = $stack.last() ?? 0
			$stack = $stack.drop_last(1)
			n = Dom.node(dom, i)
			if Dom.attr_of(n, "disabled") != "true" {
				for listener in n.hs {
					$out = $out.append((i, listener.event))
				}
			}
			var $k = n.kids.len()
			while $k > 0 {
				$k = $k - 1
				$stack = $stack.append(n.kids.get($k) ?? 0)
			}
		}
		$out
	}

	## The payload a browser would send for event `ev` on node `i`. For
	## text, half the time a value the specs typed into a control the same
	## locator finds, when they typed one, so a form's fields are often
	## valid together; otherwise one of the walk's pool.
	payload_for : Book, Dom.Model, U64, Str, U8 -> Str
	payload_for = |bk, dom, i, ev, b| {
		n = Dom.node(dom, i)
		pick = |options| options.get(b.to_u64() % options.len()) ?? ""
		typed = || {
			known = bk.typed.keep_if(|t| SpecRunner.matches(dom, n, t.loc)).map(|t| t.value)
			if !known.is_empty() and b % 2 == 0 {
				known.get((b.to_u64() / 2) % known.len()) ?? ""
			} else {
				pick(SpecRunner.pool)
			}
		}
		if ev == "input" {
			typed()
		} else if ev == "change" {
			if Dom.attr_of(n, "type") == "checkbox" {
				if (Dom.live_value(n, "checked") == "true") "false" else "true"
			} else if n.tag == "select" {
				opts = n.kids.map(|k| SpecRunner.value_of(dom, k))
				if (opts.is_empty()) "" else pick(opts)
			} else {
				typed()
			}
		} else if ev == "focus" or ev == "blur" {
			SpecRunner.value_of(dom, i)
		} else {
			""
		}
	}

	## The fault classes a walk loses a worker job to, in the order a byte
	## picks them.
	faults : List(Scm.WorkFault)
	faults = [Contract, ResourceLimit, OutOfMemory, AppCrash, ExpectFailed, Unavailable, Executor]

	## What the browser around the app can do next, besides the user: answer
	## a pending request, tick a live interval, change visibility or
	## connectivity for a live subscription, or deliver a message the specs
	## emit on a port with a live subscription.
	Service : [Answer(Pending), Tick(U32), ToggleVisibility, ToggleOnline, Emit(Str)]

	## Every service the browser can do now, in a fixed order.
	services : Book, S(state) -> List(Service)
	services = |bk, s| {
		b = s.browser
		var $out = b.pending.map(|p| Answer(p))
		var $ticks = []
		var $ports = []
		var $vis = Bool.False
		var $online = Bool.False
		for x in b.subs {
			match x.sub {
				Interval(ms) if !$ticks.contains(ms) => {
					$ticks = $ticks.append(ms)
				}
				VisibilitySub => {
					$vis = Bool.True
				}
				OnlineSub => {
					$online = Bool.True
				}
				PortSub(port, _) if !$ports.contains(port) and bk.messages.any(|m| m.port == port) => {
					$ports = $ports.append(port)
				}
				_ => {}
			}
		}
		$out = $out.concat($ticks.map(|ms| Tick(ms))).concat($ports.map(|p| Emit(p)))
		$out = if ($vis) $out.append(ToggleVisibility) else $out
		if ($online) $out.append(ToggleOnline) else $out
	}

	## The answer a walk gives an HTTP request (or an upload or a fetch):
	## by `v`, a 503, a timeout, or an HTTP response the specs give its URL (else
	## one they give its path with another query, else a network failure).
	http_answer : Book, Str, U64 -> Scm.Stub
	http_answer = |bk, url, v|
		if v % 8 == 6 {
			Reply({ url, status: 503, headers: [], body: "unavailable" })
		} else if v % 8 == 7 {
			Reject({ kind: Timeout, detail: "" })
		} else {
			path = |u| u.split_on("?").first() ?? u
			exact = bk.replies.keep_if(|r| r.url == url)
			near = if (exact.is_empty()) bk.replies.keep_if(|r| path(r.url) == path(url)) else exact
			match near.get((v / 8) % near.len().max(1)) {
				Ok({ stub: Reply(r), .. }) => Reply({ ..r, url })
				_ => bk.rejects.get((v / 8) % bk.rejects.len().max(1)) ?? Reject({ kind: Network, detail: "no spec answers ${url}" })
			}
		}

	## The answer a walk gives a call on `port`: by `v`, a throw, its
	## timeout when it has one, or an answer the specs give that port (else
	## any port, else a throw).
	port_answer : Book, Str, U32, U64 -> Scm.PortAnswer
	port_answer = |bk, port, timeout_ms, v|
		if v % 8 == 6 {
			Throw("the walk's store failed")
		} else if v % 8 == 7 and timeout_ms > 0 {
			Timeout
		} else {
			named = bk.port_answers.keep_if(|a| a.port == port).map(|a| a.answer)
			options = if (named.is_empty()) bk.loose_answers else named
			options.get((v / 8) % options.len().max(1)) ?? Throw("no spec answers port ${port}")
		}

	## Do service `service`, its variant chosen by `v`, as the spec steps
	## that would do it; a worker job runs for real in a child process
	## (`step!`), unless `v` loses it with a fault class, times it out or
	## leaves it pending. Gives the state and what was done.
	serve! : Program(state), Host, Book, S(state), Service, U64 => Try((S(state), Did), Str)
	serve! = |program, host, bk, s, service, v| {
		b = s.browser
		match service {
			Answer(p) => {
				n = (b.issued.find_first_index(|id| id == p.id) ? |_| "a pending request was never issued") + 1
				staged = |stub| { ..s, browser: { ..b, stub: Staged(stub) } }
				(op, at) = match p.kind {
					WorkRequest(w) =>
						if v % 8 == 5 {
							(LoseWork({ occurrence: n, fault: SpecRunner.faults.get((v / 8) % SpecRunner.faults.len()) ?? Executor }), s)
						} else if v % 8 == 6 and w.timeout_ms > 0 {
							(TimeOutWork(n), s)
						} else if v % 8 == 7 {
							return Ok((s, { what: "leave job ${n.to_str()} (${w.task}) pending", kind: Service }))
						} else {
							(RunEffect(n), s)
						}
					HttpRequest | UploadRequest(_) | FetchRequest => (RunEffect(n), staged(SpecRunner.http_answer(bk, p.url, v)))
					PortRequest({ port, timeout_ms, .. }) => (AnswerPort({ occurrence: n, answer: SpecRunner.port_answer(bk, port, timeout_ms, v) }), s)
					TimerRequest | ReadRequest(_) | UrlRequest(_) | DigestRequest(_) => (RunEffect(n), s)
				}
				s2 = SpecRunner.step!(program, host, at, op)?
				kind = match (p.kind, op) {
					(WorkRequest(_), RunEffect(_)) => Job
					_ => Service
				}
				Ok((s2, { what: "${Scm.op_name(op)} ${n.to_str()} ${p.url}", kind }))
			}
			Tick(ms) => Ok((SpecRunner.one(program, s, TickInterval(ms.to_u64()))?, { what: "tick-interval ${ms.to_str()}", kind: Service }))
			ToggleVisibility => Ok((SpecRunner.one(program, s, SetVisibility(if (b.visible) Hidden else Visible))?, { what: "set-visibility", kind: Service }))
			ToggleOnline => Ok((SpecRunner.one(program, s, SetOnline(if (b.online) Offline else Online))?, { what: "set-online", kind: Service }))
			Emit(port) => {
				messages = bk.messages.keep_if(|m| m.port == port)
				json = (messages.get(v % messages.len().max(1)) ?? { port, json: "null" }).json
				Ok((SpecRunner.one(program, s, EmitPort({ port, json }))?, { what: "emit-port ${port}", kind: Service }))
			}
		}
	}

	## One step of a walk, from two bytes. A pick byte of 0xC0 or more,
	## while the browser has a service to do, does one (`serve!`); otherwise
	## the user fires an event on a live control (`candidates`), typing a
	## value first for `input` and `change`. A page with nothing to do
	## stays as it is.
	walk_step! : Program(state), Host, Book, S(state), U8, U8 => Try((S(state), Did), Str)
	walk_step! = |program, host, bk, s, pick, b| {
		offered = SpecRunner.services(bk, s)
		cs = SpecRunner.candidates(s.dom)
		if pick >= 0xC0 and !offered.is_empty() {
			x = b.to_u64()
			service = offered.get(x % offered.len()) ?? crash "SpecRunner.walk_step!: a service"
			SpecRunner.serve!(program, host, bk, s, service, x / offered.len())
		} else if cs.is_empty() {
			Ok((s, { what: "nothing to do", kind: Idle }))
		} else {
			(i, ev) = cs.get(pick.to_u64() % cs.len()) ?? crash "SpecRunner.walk_step!: a candidate"
			payload = SpecRunner.payload_for(bk, s.dom, i, ev, b)
			s1 = if ev == "input" or ev == "change" {
				name = if (Dom.attr_of(Dom.node(s.dom, i), "type") == "checkbox") "checked" else "value"
				SpecRunner.set_attr(s, i, name, payload)
			} else {
				s
			}
			s2 = SpecRunner.fire(program, s1, i, ev, payload)?
			Ok((s2, { what: "${ev} ${JsonOut.quote(payload)} on <${Dom.node(s.dom, i).tag}>${SpecRunner.landmark(s.dom, i)}", kind: UserEvent }))
		}
	}

	## The step of a linear congruential generator the walks use.
	prng : U64 -> U64
	prng = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

	## The bytes of a seeded walk of `n` steps (two bytes each) from `seed`.
	seeded : U64, U64 -> List(U8)
	seeded = |seed, n| {
		var $out = List.with_capacity(2 * n)
		var $x = seed
		var $i = 0.U64
		while $i < n {
			$x = SpecRunner.prng($x)
			$out = $out.append($x.shr_zf_wrap(40).to_u8_wrap()).append($x.shr_zf_wrap(24).to_u8_wrap())
			$i = $i + 1
		}
		$out
	}

	## One thing a walk did: what, for a failure's trail, and its kind.
	Did : { what : Str, kind : [UserEvent, Service, Job, Idle] }

	## What a walk did, by kind.
	Tally : { events : U64, served : U64, jobs : U64, idle : U64 }

	## Walk an app (`--walk`): mount it with the first spec's setup, then
	## take `steps` seeded steps (`walk_step!`), the browser's requests
	## answered from the book of every spec given (`book`) and worker jobs
	## run for real. After every step the engine must be settled
	## (`check_settled`) and its counters must agree with the commands
	## (`check_counters`). A failure names the step and the last few things
	## the walk did before it.
	walk! : Program(state), Host, List(Scm.Spec), { steps : U64, seed : U64 } => Try(Tally, { step : U64, message : Str })
	walk! = |program, host, specs, { steps, seed }| {
		first = specs.first() ? |_| { step: 0, message: "a walk needs at least one spec" }
		var $s = SpecRunner.start(program, { ..first, steps: [] }).map_err(|message| { step: 0, message })?
		match SpecRunner.check_settled(program, $s) {
			Ok(_) => {}
			Err(message) => return Err({ step: 0, message: "after mount, ${message}" })
		}
		bk = SpecRunner.book(specs)
		bytes = SpecRunner.seeded(seed, steps)
		var $tally = { events: 0, served: 0, jobs: 0, idle: 0 }
		var $trail = []
		var $i = 0.U64
		while $i < steps {
			pick = bytes.get(2 * $i) ?? 0
			done = SpecRunner.walk_step!(program, host, bk, $s, pick, bytes.get(2 * $i + 1) ?? 0)
			failed = |message| Err({ step: $i + 1, message: "${message}\n  after: ${Str.join_with($trail, "\n         ")}" })
			match done {
				Ok((s2, { what, kind })) => {
					match SpecRunner.check_settled(program, s2) {
						Ok(_) => {}
						Err(message) => return failed("${what}: ${message}")
					}
					match SpecRunner.check_counters(s2) {
						Ok(_) => {}
						Err(message) => return failed("${what}: work counters: ${message}")
					}
					# Free the slots of the handles the app let go of, as the
					# runtime does after each call (`Cli.live_files!`), so a long
					# walk reuses them.
					_ = (host.live_files!)()
					$trail = $trail.append(what).take_last(6)
					$tally = match kind {
						UserEvent => { ..$tally, events: $tally.events + 1 }
						Service => { ..$tally, served: $tally.served + 1 }
						Job => { ..$tally, served: $tally.served + 1, jobs: $tally.jobs + 1 }
						Idle => { ..$tally, idle: $tally.idle + 1 }
					}
					$s = s2
				}
				Err(message) => return failed("${message} (${(host.live_files!)().to_str()} file handles live, ${$s.browser.pending.len().to_str()} requests pending)")
			}
			$i = $i + 1
		}
		Ok($tally)
	}

	## One call a spec made into the engine, as a soak records it: the node
	## and handler (for a result, the request's place among those in flight,
	## since a later cycle issues it under a new id), the payload, and the
	## handles an event carrying files held.
	Call : { node : U32, handler : [Handler(U32), InFlight(U64)], payload : List(U8), files : [Event, Files(List(Box(U64)))] }

	## An instance and the calls made into it since the recording began.
	Recorded(state) : { inst : state, calls : List(Call) }

	## `program`, recording every `event` and `files` call made into it.
	recording : Program(state) -> Program(Recorded(state))
	recording = |program| {
		init = program.init
		event = program.event
		files = program.files
		settled = program.settled
		live = program.live
		{
			version: program.version,
			keys: program.keys,
			init: |boot| {
				(inst, cmds, wbuf) = init(boot)
				({ inst, calls: [] }, cmds, wbuf)
			},
			event: |r, buf, wbuf, node, h, payload| {
				call = { node, handler: SpecRunner.handler_of(live(r.inst), node, h), payload, files: Event }
				(inst, cmds, w) = event(r.inst, buf, wbuf, node, h, payload)
				({ inst, calls: r.calls.append(call) }, cmds, w)
			},
			files: |r, buf, wbuf, node, h, record, handles| {
				call = { node, handler: SpecRunner.handler_of(live(r.inst), node, h), payload: record, files: Files(handles) }
				(inst, cmds, w) = files(r.inst, buf, wbuf, node, h, record, handles)
				({ inst, calls: r.calls.append(call) }, cmds, w)
			},
			settled: |r| settled(r.inst),
			live: |r| live(r.inst),
		}
	}

	## How a soak names the handler of a call: a result by the place of its
	## request among those in flight, anything else as it is.
	handler_of : List(U32), U32, U32 -> [Handler(U32), InFlight(U64)]
	handler_of = |live, node, h|
		if node == SpecRunner.fx_node {
			match live.find_first_index(|id| id == h) {
				Ok(i) => InFlight(i)
				Err(_) => Handler(h)
			}
		} else {
			Handler(h)
		}

	## Replay `calls` `cycles` times on the engine alone (no DOM model, the
	## command and work buffers lent back as the hosts lend them), and give
	## each cycle's net live allocations and bytes, read from the host's
	## counters before and after it. A recorded answer goes to the request
	## at its recorded place among those in flight; a cycle that has no
	## request there is not a round trip.
	replay! : Program(state), { inst : state, buf : List(U8), wbuf : List(U8) }, List(Call), U64, Host => Try(List({ allocations : I64, bytes : I64 }), Str)
	replay! = |program, { inst, buf, wbuf }, calls, cycles, host| {
		var $inst = inst
		var $buf = buf
		var $wbuf = wbuf
		var $nets = List.with_capacity(cycles)
		var $c = 0.U64
		while $c < cycles {
			allocations = (host.live_allocations!)()
			bytes = (host.live_bytes!)()
			for call in calls {
				handler = match call.handler {
					Handler(h) => h
					InFlight(i) =>
						match (program.live)($inst).get(i) {
							Ok(id) => id
							Err(_) => return Err("cycle ${($c + 1).to_str()} has no request in flight at place ${(i + 1).to_str()}, which the recorded cycle answered: the steps after the last mark-metrics do not return the app to where they started")
						}
				}
				(next, cmds, w) = match call.files {
					Event => (program.event)($inst, $buf, $wbuf, call.node, handler, call.payload)
					Files(handles) => (program.files)($inst, $buf, $wbuf, call.node, handler, call.payload, handles)
				}
				$inst = next
				$buf = cmds
				$wbuf = w
			}
			after_allocations = (host.live_allocations!)()
			after_bytes = (host.live_bytes!)()
			$nets = $nets.append({ allocations: after_allocations.to_i64_wrap() - allocations.to_i64_wrap(), bytes: after_bytes.to_i64_wrap() - bytes.to_i64_wrap() })
			$c = $c + 1
		}
		Ok($nets)
	}

	## Every cycle after the first `warm` leaves nothing live behind.
	flat : List({ allocations : I64, bytes : I64 }), U64 -> Try({}, Str)
	flat = |nets, warm|
		if nets.drop_first(warm).all(|n| n.allocations == 0 and n.bytes == 0) {
			Ok({})
		} else {
			Err("round trips leave allocations behind after ${warm.to_str()} warm-up cycles (net allocations/bytes per cycle): ${SpecRunner.show_nets(nets)}")
		}

	## Net allocations and bytes per cycle, as `allocations/bytes`.
	show_nets : List({ allocations : I64, bytes : I64 }) -> Str
	show_nets = |nets| Str.join_with(nets.map(|n| "${n.allocations.to_str()}/${n.bytes.to_str()}"), " ")

	## Soak one spec (`--soak`): run it once as `run!` does, recording the
	## calls its steps make after the last `mark-metrics` (after the mount
	## when it has none), which must take the app back to where they began;
	## then replay them `cycles` times on the engine alone and require every
	## cycle after the first `warm` to leave no allocation and no byte live.
	## A leak check, never a baseline: the counts are compared with nothing
	## but zero.
	soak! : Program(state), Host, Scm.Spec, { cycles : U64, warm : U64 } => Try(List({ allocations : I64, bytes : I64 }), Failure)
	soak! = |program, host, spec, { cycles, warm }| {
		forget = |s| {
			r = s.inst
			{ ..s, inst: { ..r, calls: [] } }
		}
		ran = SpecRunner.drive!(
			SpecRunner.recording(program),
			host,
			spec,
			{
				begin: forget,
				after: |s, op|
					match op {
						MarkMetrics => forget(s)
						_ => s
					},
			},
		)?
		last = spec.steps.last() ?? crash "a parsed spec has steps"
		failed = |message| { step: spec.steps.len() - 1, at: last, message: "soak: ${message}" }
		if ran.inst.calls.is_empty() {
			return Err(failed("the steps after the last mark-metrics call nothing in the engine, so there is no round trip to repeat"))
		}
		nets = SpecRunner.replay!(program, { inst: ran.inst.inst, buf: ran.buf, wbuf: ran.wbuf }, ran.inst.calls, cycles, host).map_err(failed)?
		SpecRunner.flat(nets, warm).map_err(failed)?
		Ok(nets)
	}

	# ------------------------------------------------------------------ CLI

	## The host services the `spec` command uses, passed in by the test
	## program (the test platform's `Cli`), so this package stays pure.
	Io : { read_file! : Str => List(U8), stdout! : Str => {}, stderr! : Str => {}, now_ns! : () => U64, work! : List(U8), List(List(U8)), List(U8), List(List(U8)), U64 => List(U8), mint_files! : U64 => List(Box(U64)), live_files! : () => U64, sha256! : List(U8) => List(U8), live_allocations! : () => U64, live_bytes! : () => U64 }

	## The command line: which specs, whether to emit their steps or the
	## grammar instead, and whether to soak them (`soak` cycles of the round
	## trip after `warm` warm-up cycles; `NoSoak` runs each spec once).
	##
	## `walk` walks the app instead (`walk!`): `steps` seeded steps from
	## `seed`, mounted as the first file's setup and answered from every
	## file's steps.
	Options : { filter : Str, emit_steps : Bool, grammar : Bool, soak : [NoSoak, Soak({ cycles : U64, warm : U64 })], walk : [NoWalk, Walk({ steps : U64, seed : U64 })], files : List(Str) }

	usage : Str
	usage = "usage: RUNNER [--filter GLOB] [--emit-steps] FILE.scm...\n       RUNNER --soak CYCLES [--warm N] FILE.scm...\n       RUNNER --walk STEPS [--seed N] FILE.scm...\n       RUNNER --grammar\n"

	## The number after an option, as a count.
	count_arg : List(Str), U64, Str -> Try(U64, Str)
	count_arg = |args, i, option| U64.from_str(args.get(i + 1) ?? "").map_err(|_| "${option} needs a count")

	parse_args : List(Str) -> Try(Options, Str)
	parse_args = |args| {
		var $o = { filter: "*", emit_steps: Bool.False, grammar: Bool.False, soak: NoSoak, walk: NoWalk, files: [] }
		var $warm = 2.U64
		var $seed = 7.U64
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
			} else if a == "--soak" {
				cycles = SpecRunner.count_arg(args, $i, a)?
				$o = { ..$o, soak: Soak({ cycles, warm: 0 }) }
				$i = $i + 2
			} else if a == "--walk" {
				steps = SpecRunner.count_arg(args, $i, a)?
				$o = { ..$o, walk: Walk({ steps, seed: 0 }) }
				$i = $i + 2
			} else if a == "--seed" {
				$seed = SpecRunner.count_arg(args, $i, a)?
				$i = $i + 2
			} else if a == "--warm" {
				$warm = SpecRunner.count_arg(args, $i, a)?
				$i = $i + 2
			} else if a.starts_with("--") {
				return Err("unknown option ${a}")
			} else {
				$o = { ..$o, files: $o.files.append(a) }
				$i = $i + 1
			}
		}
		$o = match $o.soak {
			NoSoak => $o
			Soak({ cycles, .. }) => {
				if cycles <= $warm {
					return Err("--soak needs more cycles than the ${$warm.to_str()} warm-up cycles")
				}
				{ ..$o, soak: Soak({ cycles, warm: $warm }) }
			}
		}
		$o = match $o.walk {
			NoWalk => $o
			Walk({ steps, .. }) => {
				if $o.soak != NoSoak or $o.emit_steps {
					return Err("--walk takes no --soak or --emit-steps")
				}
				{ ..$o, walk: Walk({ steps, seed: $seed }) }
			}
		}
		if $o.grammar {
			if ($o.files.is_empty() and !$o.emit_steps and $o.soak == NoSoak and $o.walk == NoWalk) Ok($o) else Err("--grammar takes no other arguments")
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
		match opts.walk {
			Walk(walk) => return SpecRunner.walk_main!(program, io, opts.files, walk)
			NoWalk => {}
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
						host = { work!: io.work!, mint_files!: io.mint_files!, live_files!: io.live_files!, sha256!: io.sha256!, live_allocations!: io.live_allocations!, live_bytes!: io.live_bytes! }
						outcome = match opts.soak {
							NoSoak => SpecRunner.run!(program, host, spec)
							Soak(soak) =>
								match SpecRunner.soak!(program, host, spec, soak) {
									Ok(nets) => {
										(io.stderr!)("soak ${id}: ${soak.cycles.to_str()} cycles flat after ${soak.warm.to_str()} warm-up cycles (net allocations/bytes per cycle: ${SpecRunner.show_nets(nets.take_first(4))} ...)\n")
										Passed
									}
									Err(failure) => Failed(failure)
								}
						}
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

	## Every spec file, parsed, or the first problem.
	parsed! : (Str => List(U8)), List(Str) => Try(List(Scm.Spec), Str)
	parsed! = |read_file!, paths| {
		var $specs = []
		for path in paths {
			match Scm.parse(Str.from_utf8(read_file!(path)) ?? "") {
				Ok(spec) => {
					$specs = $specs.append(spec)
				}
				Err(problem) => return Err(Scm.show_problem(path, problem))
			}
		}
		Ok($specs)
	}

	## Read and parse the walk's spec files and walk the app over them
	## (`walk!`): everything it allocates is its own.
	walk_files! : Program(state), Host, (Str => List(U8)), List(Str), { steps : U64, seed : U64 } => Try(Tally, { step : U64, message : Str })
	walk_files! = |program, host, read_file!, paths, walk| {
		specs = SpecRunner.parsed!(read_file!, paths).map_err(|message| { step: 0, message })?
		SpecRunner.walk!(program, host, specs, walk)
	}

	## The `--walk` command: parse every file, walk the app (`walk!`), and
	## print one `spec-result` line for the walk. Beside the settle check
	## after every step, the walk must leave nothing behind: the live
	## allocations and bytes and the live file handles after it are those
	## before it, read from the host's counters around a call whose state is
	## gone when it returns. Exit 0 when the walk passed.
	walk_main! : Program(state), Io, List(Str), { steps : U64, seed : U64 } => I32
	walk_main! = |program, io, paths, walk| {
		# Parse every file first, so a malformed one is reported as such;
		# the walk parses them again inside its measured call, so what they
		# hold is allocated and freed within it.
		match SpecRunner.parsed!(io.read_file!, paths).map_ok(|_| {}) {
			Ok({}) => {}
			Err(message) => {
				(io.stderr!)("${message}\n")
				return 2
			}
		}
		host = { work!: io.work!, mint_files!: io.mint_files!, live_files!: io.live_files!, sha256!: io.sha256!, live_allocations!: io.live_allocations!, live_bytes!: io.live_bytes! }
		t0 = (io.now_ns!)()
		allocations = (host.live_allocations!)()
		bytes = (host.live_bytes!)()
		files = (host.live_files!)()
		walked = SpecRunner.walk_files!(program, host, io.read_file!, paths, walk)
		left = { allocations: (host.live_allocations!)().to_i64_wrap() - allocations.to_i64_wrap(), bytes: (host.live_bytes!)().to_i64_wrap() - bytes.to_i64_wrap(), files: (host.live_files!)().to_i64_wrap() - files.to_i64_wrap() }
		id = "walk-${walk.steps.to_str()}-seed-${walk.seed.to_str()}"
		# The paths are read after the measured call, so their list is not
		# freed inside it, where it would count as freeing more than the
		# walk allocated.
		name = "a walk of ${walk.steps.to_str()} steps from seed ${walk.seed.to_str()} over ${Str.join_with(paths, " ")}"
		dt = (io.now_ns!)() - t0
		failure! = |step, message| {
			(io.stdout!)("${SpecRunner.result_line({ id, name, status: "failed", duration_ns: dt, failure: SpecRunner.failure_json("walk", "assertion", message, step, { line: 0, column: 0 }) })}\n")
			(io.stderr!)("walk: failed at step ${step.to_str()}: ${message}\n")
			1
		}
		match walked {
			Err({ step, message }) => failure!(step, message)
			Ok(_) if left.allocations != 0 or left.bytes != 0 or left.files != 0 => failure!(walk.steps, "the walk left ${left.allocations.to_str()} allocations, ${left.bytes.to_str()} bytes and ${left.files.to_str()} file handles live")
			Ok(t) => {
				(io.stdout!)("${SpecRunner.result_line({ id, name, status: "passed", duration_ns: dt, failure: Null })}\n")
				(io.stderr!)("walk: ${walk.steps.to_str()} steps from seed ${walk.seed.to_str()}: ${t.events.to_str()} user events, ${t.served.to_str()} services (${t.jobs.to_str()} worker jobs run), ${t.idle.to_str()} idle; nothing left live (${(dt // 1_000_000).to_str()} ms)\n")
				0
			}
		}
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

## Options parse; unknown options (the retired `--pending-phase3` among them),
## empty file lists and a soak no longer than its warm-up are refused.
expect {
	o = SpecRunner.parse_args(["--filter", "a*", "x.scm"]) ?? { filter: "", emit_steps: Bool.False, grammar: Bool.False, soak: NoSoak, walk: NoWalk, files: [] }
	soaked = SpecRunner.parse_args(["--soak", "48", "--warm", "3", "x.scm"]).map_ok(|p| p.soak)
	o.filter == "a*" and o.files == ["x.scm"] and soaked == Ok(Soak({ cycles: 48, warm: 3 })) and SpecRunner.parse_args(["--soak", "2", "x.scm"]).is_err() and SpecRunner.parse_args(["--soak", "x.scm"]).is_err() and SpecRunner.parse_args(["--pending-phase3", "x.scm"]).is_err() and SpecRunner.parse_args([]).is_err() and SpecRunner.parse_args(["--grammar"]).is_ok() and SpecRunner.parse_args(["--grammar", "x.scm"]).is_err()
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

## An answer with no files is result tag 10, a zero file count, then the
## answer's bytes.
expect SpecRunner.encode_answer([42, 0]) == [10, 0, 0, 0, 0, 42, 0]

## Exactly 4096 chained focus turns settle. Commands emitted by focus handlers
## join the same drain, which stays iterative instead of growing the call stack.
expect {
	program : SpecRunner.Program(U64)
	program = {
		version: Dom.protocol_version,
		keys: || [],
		init: |_| (0, [], []),
		event: |count, _buf, _work, node, _handler, _payload| {
			next = count + 1
			cmds = if (next == 4096) [] else SpecRunner.put_u32([18, 1], if (node == 1) 2 else 1)
			(next, cmds, List.repeat(0, 8))
		},
		files: |count, _buf, _work, _node, _handler, _payload, _files| (count, [], List.repeat(0, 8)),
		settled: |_| Ok({}),
		live: |_| [],
	}
	base = Dom.new({})
	(d1, a) = Dom.add_node(base, { ..Dom.empty_node, tag: "input", rn: 1, hs: [{ event: "focus", handler: 0, kind: 1, policies: 0 }] })
	(d2, b) = Dom.add_node(d1, { ..Dom.empty_node, tag: "input", rn: 2, hs: [{ event: "focus", handler: 0, kind: 1, policies: 0 }] })
	dom_root = base.root
	dom = Dom.bind(Dom.bind(Dom.insert(Dom.insert(d2, dom_root, a, Err(End)), dom_root, b, Err(End)), 1, a), 2, b)
	s = SpecRunner.fresh(0, SpecRunner.fresh_browser({ url: "/", storage: [], online: Bool.True, visible: Bool.True, storage_available: Bool.True }))
	done = SpecRunner.drain_focus(program, { ..s, dom, draining: Bool.True, focus_commands: [{ mode: 1, node: 1 }] })
	{ count: done.inst, turns: done.turns, queued: done.focus_commands.len(), focused: done.focused } == { count: 4096, turns: 4096, queued: 0, focused: b + 1 }
}

## Both focus effects in one batch land before either handler runs. A focus
## command from the first handler joins behind the second's queued event.
expect {
	program : SpecRunner.Program(List(U32))
	program = {
		version: Dom.protocol_version,
		keys: || [],
		init: |_| ([], [], []),
		event: |seen, _buf, _work, node, _handler, _payload| (seen.append(node), if (node == 1) SpecRunner.put_u32([18, 1], 3) else [], List.repeat(0, 8)),
		files: |seen, _buf, _work, _node, _handler, _payload, _files| (seen, [], List.repeat(0, 8)),
		settled: |_| Ok({}),
		live: |_| [],
	}
	var $dom = Dom.new({})
	for id in [1.U32, 2, 3] {
		(d, i) = Dom.add_node($dom, { ..Dom.empty_node, tag: "input", rn: id, hs: [{ event: "focus", handler: 0, kind: 1, policies: 0 }] })
		$dom = Dom.bind(Dom.insert(d, d.root, i, Err(End)), id, i)
	}
	s = SpecRunner.fresh([], SpecRunner.fresh_browser({ url: "/", storage: [], online: Bool.True, visible: Bool.True, storage_available: Bool.True }))
	done = SpecRunner.drain_focus(program, { ..s, dom: $dom, focus_commands: [{ mode: 1, node: 1 }, { mode: 1, node: 2 }] })
	{ seen: done.inst, focused: done.focused } == { seen: [1, 2, 3], focused: Dom.lookup(done.dom, 3) + 1 }
}

## A focus loop stops before its 4097th queued turn. The poisoned model
## rejects later engine calls and reports the same classified fault as Chrome.
expect {
	program : SpecRunner.Program(U64)
	program = {
		version: Dom.protocol_version,
		keys: || [],
		init: |_| (0, [], []),
		event: |count, _buf, _work, node, _handler, _payload| (count + 1, SpecRunner.put_u32([18, 1], if (node == 1) 2 else 1), List.repeat(0, 8)),
		files: |count, _buf, _work, _node, _handler, _payload, _files| (count, [], List.repeat(0, 8)),
		settled: |_| Ok({}),
		live: |_| [],
	}
	var $dom = Dom.new({})
	for id in [1.U32, 2] {
		(d, i) = Dom.add_node($dom, { ..Dom.empty_node, tag: "input", rn: id, hs: [{ event: "focus", handler: 0, kind: 1, policies: 0 }] })
		$dom = Dom.bind(Dom.insert(d, d.root, i, Err(End)), id, i)
	}
	s = SpecRunner.fresh(0, SpecRunner.fresh_browser({ url: "/", storage: [], online: Bool.True, visible: Bool.True, storage_available: Bool.True }))
	stopped = SpecRunner.drain_focus(program, { ..s, dom: $dom, focus_commands: [{ mode: 1, node: 1 }] })
	refused = SpecRunner.send(program, stopped, 1, 0, [])
	{ count: refused.inst, turns: refused.turns, check: SpecRunner.check_settled(program, refused) } == { count: 4096, turns: 4096, check: Err("resource_limit: more than 4096 turns delivered without returning to idle (an event feedback loop)") }
}

## Focus uses bubbling focusin in the browser, so the app's focus name can
## reach an ancestor. Queued focus keeps the old owner's identity: an earlier
## handler removing it and recycling its id cannot fire its replacement.
expect {
	program : SpecRunner.Program(List(U32))
	program = {
		version: Dom.protocol_version,
		keys: || [],
		init: |_| ([], [], []),
		event: |seen, _buf, _work, id, _handler, _payload| {
			cmds = if (id == 1) SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([5], 2).append(8), 2), 0), 0), "input") else []
			(seen.append(id), cmds, List.repeat(0, 8))
		},
		files: |seen, _buf, _work, _node, _handler, _payload, _files| (seen, [], List.repeat(0, 8)),
		settled: |_| Ok({}),
		live: |_| [],
	}
	var $dom = Dom.new({})
	for id in [1.U32, 2, 10] {
		(d, i) = Dom.add_node($dom, { ..Dom.empty_node, tag: "input", rn: id, hs: [{ event: "focus", handler: 0, kind: 1, policies: 0 }] })
		$dom = Dom.bind(Dom.insert(d, d.root, i, Err(End)), id, i)
	}
	(d1, child) = Dom.add_node($dom, { ..Dom.empty_node, tag: "input" })
	dom = Dom.insert(d1, Dom.lookup(d1, 10), child, Err(End))
	s = SpecRunner.fresh([], SpecRunner.fresh_browser({ url: "/", storage: [], online: Bool.True, visible: Bool.True, storage_available: Bool.True }))
	bubbled = SpecRunner.fire(program, { ..s, dom }, child, "focus", "")?
	done = SpecRunner.drain_focus(program, { ..s, dom, focus_commands: [{ mode: 1, node: 1 }, { mode: 1, node: 2 }] })
	{ ancestor: bubbled.inst, seen: done.inst, focused: done.focused, turns: done.turns } == { ancestor: [10], seen: [1], focused: 0, turns: 1 }
}

## A focus command cannot enter a hidden input, a hidden element or a hidden
## ancestor. A later removal in the same batch can retire its resolved target;
## applying that command then does nothing, as the browser's missing lookup does.
expect {
	program : SpecRunner.Program(U64)
	program = {
		version: Dom.protocol_version,
		keys: || [],
		init: |_| (0, [], []),
		event: |seen, _buf, _work, _node, _handler, _payload| (seen + 1, [], List.repeat(0, 8)),
		files: |seen, _buf, _work, _node, _handler, _payload, _files| (seen, [], List.repeat(0, 8)),
		settled: |_| Ok({}),
		live: |_| [],
	}
	var $dom = Dom.new({})
	for item in [{ id: 1.U32, tag: "input", attrs: [] }, { id: 2, tag: "input", attrs: [("type", "hidden")] }, { id: 3, tag: "input", attrs: [("hidden", "true")] }, { id: 4, tag: "div", attrs: [("hidden", "true")] }, { id: 5, tag: "input", attrs: [] }] {
		(d, i) = Dom.add_node($dom, { ..Dom.empty_node, tag: item.tag, attrs: item.attrs })
		parent = if (item.id == 5) Dom.lookup(d, 4) else d.root
		$dom = Dom.bind(Dom.insert(d, parent, i, Err(End)), item.id, i)
	}
	s = SpecRunner.fresh(0, SpecRunner.fresh_browser({ url: "/", storage: [], online: Bool.True, visible: Bool.True, storage_available: Bool.True }))
	focused = SpecRunner.drain_focus(program, { ..s, dom: $dom, focus_commands: [1.U32, 2, 3, 5].map(|id| { mode: 1, node: id }) })
	cmds = SpecRunner.put_u32([18, 1], 1).concat(SpecRunner.put_u32([5], 1))
	removed = SpecRunner.drain_focus(program, SpecRunner.take_batch(focused, 0, cmds))
	{ kept: focused.focused, removed: removed.focused, calls: removed.inst, waiting: removed.focus_commands.len() } == { kept: Dom.lookup(focused.dom, 1) + 1, removed: 0, calls: 0, waiting: 0 }
}

## A declaration's kind and policy bits survive the wire independently of
## its event name. Property commands retain their live values and mirrors.
expect {
	element = SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([8], 1), 0), 0), "input")
	listener = SpecRunner.put_u32(SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32([11], 1), 7), "change").append(2), 2)
	value = SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(1), "first")
	checked = SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(2), "true")
	decoded = Dom.apply_full(Dom.new({}), element.concat(listener).concat(value).concat(checked))
	i = Dom.lookup(decoded.dom, 1)
	target = Dom.target(decoded.dom, i, "change", Bool.True)?
	n = Dom.node(decoded.dom, i)
	{ target, value: Dom.live_value(n, "value"), checked: Dom.live_value(n, "checked"), mirror: Dom.attr_of(n, "value"), values: decoded.values, writes: decoded.written } == {
		target: { node: 1, handler: 7, event: "change", kind: 2, policies: 2 },
		value: "first",
		checked: "true",
		mirror: "first",
		values: [(i, "first")],
		writes: [i, i],
	}
}

## A property template hole consumes one value at INST and HPROP updates
## that same resolved element. Its sibling event hole keeps its own kind.
expect {
	tree = SpecRunner.put_str([1], "input").concat([0, 0])
	holes = SpecRunner.put_u32(SpecRunner.put_str([2, 6, 0, 2, 3, 0, 0], "change").append(1), 1)
	template = tree.concat(holes)
	define = SpecRunner.put_u32(SpecRunner.put_u32([7], 0), template.len().to_u32_wrap()).concat(template)
	instance = SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([1], 1), 0), 0), 0), "false")
	update = SpecRunner.put_str(SpecRunner.put_u32([22], 1).append(0), "true")
	decoded = Dom.apply_full(Dom.new({}), define.concat(instance).concat(update))
	i = Dom.lookup(decoded.dom, 1)
	{ checked: Dom.live_value(Dom.node(decoded.dom, i), "checked"), target: Dom.target(decoded.dom, i, "change", Bool.True)?, writes: decoded.written, ops: decoded.ops } == {
		checked: "true",
		target: { node: 1, handler: 0, event: "change", kind: 1, policies: 1 },
		writes: [i],
		ops: [7, 1, 22],
	}
}

## An ordinary value attribute on a custom element never overwrites its
## own live property. The spec's attribute and value assertions see each.
expect {
	(d1, i) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "custom-field", props: [("value", "live")] })
	dom = Dom.bind(d1, 1, i)
	attribute = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32([9], 1), "value").append(1), "attribute")
	decoded = Dom.apply(dom, attribute)
	{ attr: SpecRunner.attr_value(decoded, i, "value")?, value: SpecRunner.value_of(decoded, i) } == { attr: "attribute", value: "live" }
}

## Attribute commands retain empty text independently from absence. The
## same distinction survives static template attributes, INST operands and
## HATTR updates, without changing ordinary checked attributes into properties.
expect {
	element = SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([8], 1), 0), 0), "img")
	empty_alt = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32([9], 1), "alt").append(1), "")
	removed_alt = SpecRunner.put_str(SpecRunner.put_u32([9], 1), "alt").append(0)
	ordinary_checked = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32([9], 1), "checked").append(1), "")
	present = Dom.apply(Dom.new({}), element.concat(empty_alt).concat(ordinary_checked))
	i = Dom.lookup(present, 1)
	removed = Dom.apply(present, removed_alt)
	static_attrs = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_str([1], "img").append(1), "alt"), "")
	template = SpecRunner.put_str(static_attrs.concat([0, 1, 2, 0]), "aria-label")
	define = SpecRunner.put_u32(SpecRunner.put_u32([7], 0), template.len().to_u32_wrap()).concat(template)
	instance = SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([1], 2), 0), 0), 0).append(1), "")
	row_present = Dom.apply(removed, define.concat(instance))
	row = Dom.lookup(row_present, 2)
	row_absent = Dom.apply(row_present, SpecRunner.put_u32([3], 2).concat([0, 0]))
	row_restored = Dom.apply(row_absent, SpecRunner.put_str(SpecRunner.put_u32([3], 2).concat([0, 1]), ""))
	actual = {
		plain_empty: SpecRunner.attr_value(present, i, "alt")?,
		ordinary_checked: SpecRunner.attr_value(present, i, "checked")?,
		plain_absent: SpecRunner.attr_value(removed, i, "alt"),
		static_empty: SpecRunner.attr_value(row_present, row, "alt")?,
		row_empty: SpecRunner.attr_value(row_present, row, "aria-label")?,
		row_absent: SpecRunner.attr_value(row_absent, row, "aria-label"),
		row_restored: SpecRunner.attr_value(row_restored, row, "aria-label")?,
	}
	actual == { plain_empty: "", ordinary_checked: "", plain_absent: Err(Absent), static_empty: "", row_empty: "", row_absent: Err(Absent), row_restored: "" }
}

## Locators and focusability use presence rather than nonempty text. Empty
## labels and test ids locate only elements that actually declare them.
expect {
	dom = Dom.new({})
	plain = { ..Dom.empty_node, tag: "a" }
	empty = { ..plain, attrs: [("aria-label", ""), ("data-testid", ""), ("href", "")] }
	actual = {
		missing_label: SpecRunner.matches(dom, plain, Label("")),
		empty_label: SpecRunner.matches(dom, empty, Label("")),
		missing_id: SpecRunner.matches(dom, plain, TestId("")),
		empty_id: SpecRunner.matches(dom, empty, TestId("")),
		missing_href: SpecRunner.focusable(plain),
		empty_href: SpecRunner.focusable(empty),
	}
	actual == { missing_label: Bool.False, empty_label: Bool.True, missing_id: Bool.False, empty_id: Bool.True, missing_href: Bool.False, empty_href: Bool.True }
}

## An empty option value is distinct from an absent one: only the absent
## value falls back to the option's text. Empty controlled values retain their
## mirrors, while checked false removes its mirror explicitly.
expect {
	(d1, select) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "select" })
	(d2, option) = Dom.add_node(d1, { ..Dom.empty_node, tag: "option" })
	(d3, text) = Dom.add_node(d2, { ..Dom.empty_node, text: "All works" })
	(d4, input) = Dom.add_node(d3, { ..Dom.empty_node, tag: "input" })
	tree = Dom.insert(Dom.insert(d4, select, option, Err(End)), option, text, Err(End))
	values = Dom.set_property_on(Dom.set_property_on(tree, option, 1, "", 2), select, 1, "", 1)
	checked = Dom.set_property_on(Dom.set_property_on(values, input, 2, "true", 3), input, 2, "false", 3)
	actual = {
		fallback: SpecRunner.value_of(tree, option),
		empty_option: SpecRunner.value_of(checked, option),
		select_match: SpecRunner.has_option(checked, { root: select, value: "" }),
		option_mirror: Dom.node(checked, option).attrs,
		select_mirror: Dom.node(checked, select).attrs,
		unchecked_mirror: Dom.node(checked, input).attrs,
	}
	actual == { fallback: "All works", empty_option: "", select_match: Bool.True, option_mirror: [("value", "")], select_mirror: [("value", "")], unchecked_mirror: [] }
}

## A checkbox without a declared value has the browser's default "on".
## A button's ordinary value attribute reflects its own standard property,
## so its focus payload remains that value without a PROP declaration.
expect {
	program : SpecRunner.Program(List(Str))
	program = {
		version: Dom.protocol_version,
		keys: || [],
		init: |_| ([], [], []),
		event: |seen, _buf, _work, _node, _handler, payload| (seen.append(Str.from_utf8(payload) ?? crash "test payload is UTF-8"), [], List.repeat(0, 8)),
		files: |seen, _buf, _work, _node, _handler, _payload, _files| (seen, [], List.repeat(0, 8)),
		settled: |_| Ok({}),
		live: |_| [],
	}
	(d1, checkbox) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "input", rn: 1, attrs: [("type", "checkbox"), ("aria-label", "Raw checkbox")], hs: [{ event: "change", handler: 0, kind: 1, policies: 0 }] })
	(d2, button) = Dom.add_node(d1, { ..Dom.empty_node, tag: "button", rn: 2, attrs: [("value", "button payload"), ("aria-label", "Value button")], hs: [{ event: "focus", handler: 0, kind: 1, policies: 0 }] })
	dom = Dom.bind(Dom.bind(Dom.insert(Dom.insert(d2, d2.root, checkbox, Err(End)), d2.root, button, Err(End)), 1, checkbox), 2, button)
	s = SpecRunner.fresh([], SpecRunner.fresh_browser({ url: "/", storage: [], online: Bool.True, visible: Bool.True, storage_available: Bool.True }))
	changed = SpecRunner.one(program, { ..s, dom }, Change(Label("Raw checkbox"), "on"))?
	focused = SpecRunner.one(program, changed, Focus(Label("Value button")))?
	{ events: focused.inst, checkbox: Dom.live_value(Dom.node(focused.dom, checkbox), "checked"), default: SpecRunner.value_of(focused.dom, checkbox), button: SpecRunner.value_of(focused.dom, button) } == {
		events: ["true", "button payload"],
		checkbox: "true",
		default: "on",
		button: "button payload",
	}
}

## Only a files declaration stages handles. The same selected files reach a
## text declaration as its ordinary file-input value, and an empty choice
## reaches text but dispatches nothing to a files declaration.
expect {
	program : SpecRunner.Program({ events : List(Str), files : U64 })
	program = {
		version: Dom.protocol_version,
		keys: || [],
		init: |_| ({ events: [], files: 0 }, [], []),
		event: |seen, _buf, _work, _node, _handler, payload| ({ ..seen, events: seen.events.append(Str.from_utf8(payload) ?? crash "test payload is UTF-8") }, [], List.repeat(0, 8)),
		files: |seen, _buf, _work, _node, _handler, _payload, _files| ({ ..seen, files: seen.files + 1 }, [], List.repeat(0, 8)),
		settled: |_| Ok({}),
		live: |_| [],
	}
	(d1, input) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "input", rn: 1, attrs: [("type", "file"), ("aria-label", "Choice")], hs: [{ event: "change", handler: 0, kind: 2, policies: 0 }] })
	dom = Dom.bind(Dom.insert(d1, d1.root, input, Err(End)), 1, input)
	base = SpecRunner.fresh({ events: [], files: 0 }, SpecRunner.fresh_browser({ url: "/", storage: [], online: Bool.True, visible: Bool.True, storage_available: Bool.True }))
	s = { ..base, dom, browser: { ..base.browser, files: [{ name: "a.txt", mime: "text/plain", bytes: [65] }] } }
	op = ChooseFiles(Label("Choice"), ["a.txt"])
	text = Dom.modify(dom, input, |n| { ..n, hs: [{ event: "change", handler: 0, kind: 1, policies: 0 }] })
	with_text = SpecRunner.give_files(program, { ..s, dom: text }, op, [])?
	empty_text = SpecRunner.give_files(program, with_text, ChooseFiles(Label("Choice"), []), [])?
	empty_files = SpecRunner.give_files(program, s, ChooseFiles(Label("Choice"), []), [])?
	{ files_count: SpecRunner.file_count(dom, op)?, text_count: SpecRunner.file_count(text, op)?, events: empty_text.inst.events, files: empty_files.inst.files } == {
		files_count: 1,
		text_count: 0,
		events: ["C:\\fakepath\\a.txt", ""],
		files: 0,
	}
}
