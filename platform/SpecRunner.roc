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

	Sub : [Interval(U32), Pop, OnlineSub, VisibilitySub, MediaSub(Str), PortSub(Str, Str), StorageSub(Str), StorageFailures]

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
	## a cross-document navigation mounts the app afresh in the next one. `env`
	## starts as the parser's resolved facts and holds their current values.
	Browser : {
		env : Scm.Environment,
		doc : U64,
		back : List(Entry),
		fwd : List(Entry),
		title : Str,
		pending : List(Pending),
		issued : List(U32),
		gets : List([Read({ id : U32, key : Str, session : Bool }), Answer({ id : U32, payload : List(U8), scoped : Bool }), Failures]),
		failure_queue : List({ id : U32, payload : List(U8), ready : Bool }),
		failure_scheduled : Bool,
		failure_active : Bool,
		settings : { local_full : Bool, session_full : Bool, clipboard_denied : Bool, max_paste : U64 },
		guard : Bool,
		sticky_activation : Bool,
		clipboard : { text : Str, html : Str, writes : U64, exhausted : Bool },
		deferred_error : Str,
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

		## The catalogue chooses which port messages report a current value.
		latest_ports : List(Str),
		pointers : Dict(U32, PointerState),
		touch_multi : Bool,
		top_layer : List(U64),
		openers : Dict(U64, U64),
		ui_tasks : List(UiTask),
		ui_head : U64,
		ui_exhausted : Bool,
		cancel_allowed : Bool,
		scrolls : List(ScrollRecord),
		scroll_count : U64,
		scroll_exhausted : Bool,
		scroll_error : Str,

		## Live report sources are indexed so cancelling or delivering one
		## never searches the full subscription set.
		report_sources : Dict(U32, {}),

		## Policy metadata for pending network requests only; removed by final
		## delivery or cancel, so the engine’s in-flight cap bounds this map.
		network : Dict(U32, { method : Str, options : Dom.HttpOptions }),

		## One source index and epoch over the same ingress queue as focus
		## callbacks. Slots are absolute while a drain removes its prefix.
		reports : { held : Bool, releasing : Bool, replaced : U64, epoch : U64, head : U64, index : Dict(ReportSource, { epoch : U64, slot : U64 }) },
	}

	## Browser task-source entries keep only never-reused model lifetimes.
	UiTask : [Toggle(U64), Close(U64), Cancelled]
	ScrollRecord : { ordinal : U64, target : U64, action : Dom.RefAction }

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
		after_batch : List(Dom.AfterCmd),
		event_queue : List(Input),
		applying_focus : Bool,
		draining : Bool,
		turns : U64,
		fault : [Healthy, Poisoned(Str)],
	}

	## One ingress entry; its source fixes replacement, never its payload.
	Input : { node : U32, handler : U32, payload : List(U8), owner : U64, source : [Occurrence, Report(ReportSource)] }

	## Request ids and DOM pointer sources cannot alias. A DOM source follows
	## its declaring element's lifetime, handler and pointer independently.
	ReportSource := [Request(U32), Pointer({ element : U64, handler : U32, pointer : U32 }), Scroll({ element : U64, handler : U32 }), Observation({ element : U64, kind : U8 })].{
		is_eq : _
		to_hash : _
	}

	PointerAt : [Outside, In({ zone : Str, x : U16, y : U16 })]
	PointerState : { id : U32, kind : [Mouse, Pen, Touch], button : [Main, Middle, Secondary], modifiers : U8, primary : Bool, down : U64, capture : U64, moved : Bool, suppress_mouse : Bool, at : PointerAt }

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

	## Read the local-storage declaration section the program's keys encoder
	## wrote. Both mandatory declaration sections are consumed exactly, including
	## the port catalogue the native runner does not otherwise need.
	decode_keys : List(U8) -> List(Str)
	decode_keys = |b| SpecRunner.decode_declarations(b).keys

	## Decode both declaration sections once: only the catalogue decides
	## whether a subscription's messages are reports.
	decode_declarations : List(U8) -> { keys : List(Str), latest_ports : List(Str), media : List(Str), zone_days : U16, session_keys : List(Str) }
	decode_declarations = |b| {
		if b.first() != Ok(2) {
			crash "contract: declaration section 2 (local-storage) is missing"
		}
		len = (SpecRunner.get_u32(b, 1) ?? crash "contract: declaration section 2 (local-storage) has a short header").to_u64()
		if len > b.len() - 5 {
			crash "contract: declaration section 2 (local-storage) has a short body"
		}
		body = b.sublist({ start: 5, len })
		n = SpecRunner.get_u32(body, 0) ?? crash "contract: declaration section 2 (local-storage) has a short key count"
		var $at = 4.U64
		var $keys = []
		var $i = 0.U32
		while $i < n {
			key_len = (SpecRunner.get_u32(body, $at) ?? crash "contract: declaration section 2 (local-storage) has a short key").to_u64()
			if key_len > body.len() - $at - 4 {
				crash "contract: declaration section 2 (local-storage) has a short key"
			}
			key = Str.from_utf8(body.sublist({ start: $at + 4, len: key_len })) ?? crash "contract: declaration section 2 (local-storage) key is not UTF-8"
			$keys = $keys.append(key)
			$at = $at + 4 + key_len
			$i = $i + 1
		}
		if $at != body.len() {
			crash "contract: declaration section 2 (local-storage) has trailing bytes"
		}
		port_at = 5 + len
		if b.get(port_at) != Ok(5) {
			crash "contract: declaration section 5 (ports) is missing or out of order"
		}
		port_len = (SpecRunner.get_u32(b, port_at + 1) ?? crash "contract: declaration section 5 (ports) has a short header").to_u64()
		if port_len > b.len() - port_at - 5 {
			crash "contract: declaration section 5 (ports) has a short body or trailing bytes"
		}
		ports = b.sublist({ start: port_at + 5, len: port_len })
		count = SpecRunner.get_u32(ports, 0) ?? crash "contract: declaration section 5 (ports) has a short count"
		if count > 64 {
			crash "contract: declaration section 5 (ports) has more than 64 ports"
		}
		$at = 4
		$i = 0
		var $names = []
		var $latest_ports = []
		while $i < count {
			name_len = (SpecRunner.get_u32(ports, $at) ?? crash "contract: declaration section 5 (ports) has a short name").to_u64()
			if name_len < 1 or name_len > 128 or name_len > ports.len() - $at - 4 {
				crash "contract: declaration section 5 (ports) has an invalid name length"
			}
			name = Str.from_utf8(ports.sublist({ start: $at + 4, len: name_len })) ?? crash "contract: declaration section 5 (ports) name is not UTF-8"
			if $names.contains(name) {
				crash "contract: declaration section 5 (ports) has a duplicate name"
			}
			$names = $names.append(name)
			$at = $at + 4 + name_len
			kind = ports.get($at) ?? crash "contract: declaration section 5 (ports) has a short kind"
			delivery = ports.get($at + 1) ?? crash "contract: declaration section 5 (ports) has a short delivery"
			bound = SpecRunner.get_u32(ports, $at + 2) ?? crash "contract: declaration section 5 (ports) has a short bound"
			is_shape = match kind {
				1 | 2 => delivery == 0 and bound == 0
				3 => (delivery == 1 and bound >= 1 and bound <= 1024) or (delivery == 2 and bound == 1)
				_ => Bool.False
			}
			if !is_shape {
				crash "contract: declaration section 5 (ports) has an invalid shape"
			}
			if kind == 3 and delivery == 2 {
				$latest_ports = $latest_ports.append(name)
			}
			$at = $at + 6
			$i = $i + 1
		}
		if $at != ports.len() {
			crash "contract: declaration section 5 (ports) has trailing body bytes"
		}
		media_at = port_at + 5 + port_len
		if b.get(media_at) != Ok(6) {
			crash "contract: declaration section 6 (media) is missing or out of order"
		}
		media_len = (SpecRunner.get_u32(b, media_at + 1) ?? crash "contract: declaration section 6 (media) has a short header").to_u64()
		if media_len > b.len() - media_at - 5 {
			crash "contract: declaration section 6 (media) has a short body or trailing bytes"
		}
		media = b.sublist({ start: media_at + 5, len: media_len })
		media_count = SpecRunner.get_u32(media, 0) ?? crash "contract: declaration section 6 (media) has a short count"
		if media_count > 32 {
			crash "contract: declaration section 6 (media) has more than 32 queries"
		}
		$at = 4
		$i = 0
		var $queries = []
		while $i < media_count {
			query_len = (SpecRunner.get_u32(media, $at) ?? crash "contract: declaration section 6 (media) has a short query").to_u64()
			if query_len < 1 or query_len > 256 or query_len > media.len() - $at - 4 {
				crash "contract: declaration section 6 (media) has an invalid query length"
			}
			query = Str.from_utf8(media.sublist({ start: $at + 4, len: query_len })) ?? crash "contract: declaration section 6 (media) query is not UTF-8"
			if $queries.contains(query) {
				crash "contract: declaration section 6 (media) has a duplicate query"
			}
			$queries = $queries.append(query)
			$at = $at + 4 + query_len
			$i = $i + 1
		}
		if $at != media.len() {
			crash "contract: declaration section 6 (media) has trailing body bytes"
		}
		zone_at = media_at + 5 + media_len
		if b.get(zone_at) != Ok(10) {
			crash "contract: declaration section 10 (time-zone) is missing or out of order"
		}
		zone_len = SpecRunner.get_u32(b, zone_at + 1) ?? crash "contract: declaration section 10 (time-zone) has a short header"
		if zone_len != 2 {
			crash "contract: declaration section 10 (time-zone) needs exactly two days bytes"
		}
		days = (b.get(zone_at + 5) ?? crash "contract: declaration section 10 truncated days").to_u16() + (b.get(zone_at + 6) ?? crash "contract: declaration section 10 truncated days").to_u16().shl_wrap(8)
		if days > 7305 {
			crash "contract: declaration section 10 (time-zone) days exceed 7305"
		}
		session_at = zone_at + 7
		if b.get(session_at) != Ok(11) {
			crash "contract: declaration section11 session-storage missing"
		}
		length = (SpecRunner.get_u32(b, session_at + 1) ?? crash "contract: session-storage short length").to_u64()
		if session_at + 5 + length != b.len() {
			crash "contract: session-storage length mismatch"
		}
		session_body = b.sublist({ start: session_at + 5, len: length })
		session_count = (SpecRunner.get_u32(session_body, 0) ?? crash "contract: session-storage missing key session_count").to_u64()
		var $session_cursor = 4.U64
		var $session = []
		while $session.len() < session_count {
			(key, next) = Dom.str(session_body, $session_cursor)
			$session_cursor = next
			$session = $session.append(key)
		}
		if $session_cursor != session_body.len() {
			crash "contract: session-storage trailing bytes"
		}
		{ keys: $keys, latest_ports: $latest_ports, media: $queries, zone_days: days, session_keys: $session }
	}

	flag_byte : Bool -> U8
	flag_byte = |b| if (b) 1 else 0

	## One length-bounded boot section. The runner writes every section in
	## protocol order; its encoder is independent of the engine's decoder.
	put_section : List(U8), { tag : U8, body : List(U8) } -> List(U8)
	put_section = |bytes, { tag, body }| SpecRunner.put_u32(bytes.append(tag), body.len().to_u32_wrap()).concat(body)

	## Encode the resolved browser facts as the mandatory boot sections. The
	## caller filters local storage to the program's declared keys first.
	encode_boot : Scm.Environment -> List(U8)
	encode_boot = |env| {
		var $storage = SpecRunner.put_u32([SpecRunner.flag_byte(env.storage_available)], env.storage.len().to_u32_wrap())
		for (key, value) in env.storage {
			$storage = SpecRunner.put_str(SpecRunner.put_str($storage, key), value)
		}
		var $seed = []
		var $number = env.seed
		var $byte = 0.U64
		while $byte < 16 {
			$seed = $seed.append($number.to_u8_wrap())
			$number = $number.shr_zf_wrap(8)
			$byte = $byte + 1
		}
		languages = env.languages.fold(SpecRunner.put_u32([], env.languages.len().to_u32_wrap()), SpecRunner.put_str)
		zone = env.zone
		var $offsets = SpecRunner.put_u32(SpecRunner.put_u64(SpecRunner.put_u64(SpecRunner.put_str([], zone.name), zone.from_ms.to_u64_wrap()), zone.until_ms.to_u64_wrap()), zone.offsets.len().to_u32_wrap())
		for offset in zone.offsets {
			$offsets = SpecRunner.put_u32(SpecRunner.put_u64($offsets, offset.from_ms.to_u64_wrap()), offset.minutes.to_u32_wrap())
		}
		[
			{ tag: 1, body: SpecRunner.put_str([], env.url) },
			{ tag: 2, body: $storage },
			{ tag: 3, body: [SpecRunner.flag_byte(env.online)] },
			{ tag: 4, body: [SpecRunner.flag_byte(env.visible)] },
			{ tag: 6, body: env.media.map(|(_, matches)| SpecRunner.flag_byte(matches)) },
			{ tag: 7, body: SpecRunner.put_u64([], env.now_ms.to_u64_wrap()) },
			{ tag: 8, body: $seed },
			{ tag: 9, body: languages },
			{ tag: 10, body: $offsets },
			{ tag: 11, body: env.session.fold(SpecRunner.put_u32([SpecRunner.flag_byte(env.session_available)], env.session.len().to_u32_wrap()), |bytes, (key, value)| SpecRunner.put_str(SpecRunner.put_str(bytes, key), value)) },
		].fold([], SpecRunner.put_section)
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
		var $s = { ..s, inst, buf: cmds }
		var $at = 0.U64
		while $at < cmds.len() {
			prior = $s
			r = Dom.apply_next(prior.dom, cmds, $at)
			$at = r.next
			var $ops = prior.ops
			for op in r.ops {
				$ops = $ops.set(op.to_u64(), ($ops.get(op.to_u64()) ?? 0) + 1) ?? $ops
			}
			var $w = prior.writes
			while $w.len() < r.dom.nodes.len() {
				$w = $w.append(0)
			}
			for i in r.written {
				if i < before {
					$w = $w.set(i, ($w.get(i) ?? 0) + 1) ?? $w
					n = Dom.node(r.dom, i)
					if n.tag == "" and n.parent != 0 {
						$w = $w.set(n.parent - 1, ($w.get(n.parent - 1) ?? 0) + 1) ?? $w
					}
				}
			}
			focused = if (prior.focused != 0 and !SpecRunner.attached(r.dom, prior.focused - 1)) 0 else prior.focused
			held = SpecRunner.hold_focused({ ..prior, focused }, r.dom, r.values)
			$s = { ..prior, dom: held.dom, focused, deferred: held.deferred, browser: prior.browser, ops: $ops, writes: $w }
			for fx in r.fx {
				match fx {
					Ref(command) => {
						$s = { ..$s, after_batch: $s.after_batch.append(Ref(command)) }
					}
					Shown(command) => {
						# Closing happens now, before a following REMOVE can erase content.
						if command.value == Hidden {
							$s = SpecRunner.change_shown($s, command.target, Hidden)
						}
						else {
							$s = { ..$s, after_batch: $s.after_batch.append(Show(command)) }
						}
					}
					_ => {
						$s = { ..$s, after_batch: $s.after_batch.append(Effect(fx)) }
					}
				}
			}
			if r.ops == [4] {
				for i in $s.browser.top_layer {
					if Dom.node(prior.dom, i).detach_count != Dom.node($s.dom, i).detach_count or SpecRunner.pressed_path($s.dom, i).any(|p| Dom.node(prior.dom, p.node).detach_count != p.count) {
						value = if (Dom.node($s.dom, i).shown == Modal) Open else Hidden
						$s = { ..$s, dom: Dom.modify($s.dom, i, |n| { ..n, shown: value }), focused: if ($s.focused != 0 and SpecRunner.inside($s.dom, $s.focused - 1, i)) 0 else $s.focused }
					}
				}
				b = $s.browser
				$s = { ..$s, browser: { ..b, top_layer: b.top_layer.keep_if(|i| Dom.node($s.dom, i).shown == Modal or Dom.node($s.dom, i).shown == Popover) } }
			}
			# Detached top-layer lifetimes do not restore focus or invent close events.
			b = $s.browser
			$s = { ..$s, browser: { ..b, top_layer: b.top_layer.keep_if(|i| SpecRunner.attached($s.dom, i)) } }
		}
		if cmds.first() == Ok(1) {
			# The browser starts non-node effects before the deferred DOM update.
			# Native application has no animation gap, but retains that ordering.
			prior = $s
			queued = prior.after_batch.drop_first(s.after_batch.len())
			early = |command| match command {
				Effect(_) => True
				Ref(_) | Show(_) => False
			}
			$s = { ..prior, after_batch: s.after_batch.concat(queued.keep_if(early)).concat(queued.keep_if(|command| !early(command))) }
		}
		$s
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
		browser = SpecRunner.fresh_browser({ url, storage: storage.map(|kv| (kv.key, kv.value)) })
		s0 = SpecRunner.fresh(inst, browser)
		SpecRunner.take_batch(s0, inst, cmds)
	}

	## The modelled browser of a fresh document at `url`.
	fresh_browser : Scm.Environment -> Browser
	fresh_browser = |env| {
		env,
		doc: 0,
		back: [],
		fwd: [],
		title: "",
		pending: [],
		issued: [],
		gets: [],
		failure_queue: [],
		failure_scheduled: False,
		failure_active: False,
		settings: { local_full: False, session_full: False, clipboard_denied: False, max_paste: 4194304 },
		guard: False,
		sticky_activation: False,
		clipboard: { text: "", html: "", writes: 0, exhausted: False },
		deferred_error: "",
		subs: [],
		stub: NoStub,
		files: [],
		given: [],
		port_log: [],
		saves: [],
		max_output: SpecRunner.max_output_bytes,
		latest_ports: [],
		pointers: Dict.empty(),
		touch_multi: Bool.False,
		top_layer: [],
		openers: Dict.empty(),
		ui_tasks: [],
		ui_head: 0,
		ui_exhausted: False,
		cancel_allowed: Bool.False,
		scrolls: [],
		scroll_count: 0,
		scroll_exhausted: Bool.False,
		scroll_error: "",
		report_sources: Dict.empty(),
		network: Dict.empty(),
		reports: { held: Bool.False, releasing: Bool.False, replaced: 0, epoch: 0, head: 0, index: Dict.empty() },
	}

	## A runner state for instance `inst` before its first batch.
	fresh : state, Browser -> S(state)
	fresh = |inst, browser| { inst, buf: [], wbuf: [], dom: Dom.new({}), browser, work: { counters: [], cleanups: [] }, ops: List.repeat(0, 26), writes: [], mark: [], focused: 0, focus_value: "", deferred: NoValue, after_batch: [], event_queue: [], applying_focus: Bool.False, draining: Bool.False, turns: 0, fault: Healthy }

	set_store : List((Str, Str)), Str, Str -> List((Str, Str))
	set_store = |l, key, value| l.keep_if(|(name, _)| name != key).append((key, value))

	## Apply one batch's effect commands to the modelled browser.
	absorb : Browser, List(Dom.FxCmd) -> Browser
	absorb = |browser, commands| SpecRunner.absorb_limit(browser, commands, 4096)

	## Failure callbacks share the ingress capacity, including while effects run.
	absorb_limit : Browser, List(Dom.FxCmd), U64 -> Browser
	absorb_limit = |b0, fx, capacity| {
		var $b = b0
		for c in fx {
			if !$b.deferred_error.is_empty() {
				break
			}
			b = $b
			$b = match c {
				Http(id, method, url, _, body, _, options) => { ..b, network: b.network.insert(id, { method, options }), report_sources: if (options.progress_ms > 0) b.report_sources.insert(id, {}) else b.report_sources, pending: b.pending.append({ id, url, body, kind: HttpRequest }), issued: b.issued.append(id) }
				Guard(on) => { ..b, guard: on }
				SessionGet(id, key) => { ..b, gets: b.gets.append(Read({ id, key, session: True })) }
				StorageSub(id, key) => { ..b, subs: b.subs.append({ id, sub: StorageSub(key) }), report_sources: b.report_sources.insert(id, {}) }
				StorageFailures(id) => { ..b, subs: b.subs.append({ id, sub: StorageFailures }) }
				Clipboard(id, value) => {
					denied = b.settings.clipboard_denied
					{
						..b,
						clipboard: if (denied) b.clipboard else {
							text: value.text,
							html: match value.html {
								Plain => ""
								Html(markup) => markup
							},
							writes: if (b.clipboard.writes == 18446744073709551615) b.clipboard.writes else b.clipboard.writes + 1,
							exhausted: b.clipboard.exhausted or b.clipboard.writes == 18446744073709551615,
						},
						gets: b.gets.append(Answer({ id, payload: if (denied) [24, 1] else [23], scoped: False })),
					}
				}
				SessionSet(key, value) => SpecRunner.storage_write(b, { capacity, session: True, key, value: Present(value) })
				SessionRemove(key) => SpecRunner.storage_write(b, { capacity, session: True, key, value: Absent })
				Get(id, key) => { ..b, gets: b.gets.append(Read({ id, key, session: False })) }
				Timer(id, _) => { ..b, pending: b.pending.append({ id, url: "timer", body: "", kind: TimerRequest }), issued: b.issued.append(id) }
				Work(id, job) => { ..b, pending: b.pending.append({ id, url: "work", body: "", kind: WorkRequest(job) }), issued: b.issued.append(id) }
				Interval(id, ms) => { ..b, subs: b.subs.append({ id, sub: Interval(ms) }) }
				Pop(id) => { ..b, subs: b.subs.append({ id, sub: Pop }) }
				OnlineSub(id) => { ..b, subs: b.subs.append({ id, sub: OnlineSub }), report_sources: b.report_sources.insert(id, {}) }
				VisibilitySub(id) => { ..b, subs: b.subs.append({ id, sub: VisibilitySub }), report_sources: b.report_sources.insert(id, {}) }
				MediaSub(id, query) => { ..b, subs: b.subs.append({ id, sub: MediaSub(query) }), report_sources: b.report_sources.insert(id, {}) }
				Cancel(id) => {
					failures = b.failure_queue.keep_if(|entry| entry.id != id)
					tasks = b.gets.keep_if(
						|task| match task {
							Answer(answer) => answer.id != id
							Read(read) => read.id != id
							Failures => !failures.is_empty()
						},
					)
					{ ..b, pending: b.pending.keep_if(|request| request.id != id), subs: b.subs.keep_if(|entry| entry.id != id), gets: tasks, failure_queue: failures, failure_scheduled: b.failure_scheduled and !failures.is_empty(), reports: { ..b.reports, index: b.reports.index.remove(Request(id)) }, report_sources: b.report_sources.remove(id), network: b.network.remove(id) }
				}
				Push(url) => { ..b, back: b.back.append({ url: b.env.url, doc: b.doc }), env: { ..b.env, url: SpecRunner.resolve_in_document(b.env.url, url) }, fwd: [] }
				Replace(url) => { ..b, env: { ..b.env, url: SpecRunner.resolve_in_document(b.env.url, url) } }
				# Writes to unavailable storage fail in the browser and persist nothing.
				Set(key, value) => SpecRunner.storage_write(b, { capacity, session: False, key, value: Present(value) })
				Remove(key) => SpecRunner.storage_write(b, { capacity, session: False, key, value: Absent })
				Title(t) => { ..b, title: t }
				Ref(_) | Shown(_) => b
				FileRead(id, mode, file, max_bytes) => { ..b, pending: b.pending.append({ id, url: "read", body: "", kind: ReadRequest({ mode, file, max_bytes }) }), issued: b.issued.append(id) }
				Upload(id, method, url, _, file, _, options) => { ..b, network: b.network.insert(id, { method, options }), report_sources: if (options.progress_ms > 0) b.report_sources.insert(id, {}) else b.report_sources, pending: b.pending.append({ id, url, body: "", kind: UploadRequest(file) }), issued: b.issued.append(id) }
				Digest(id, _, file) => { ..b, pending: b.pending.append({ id, url: "digest", body: "", kind: DigestRequest(file) }), issued: b.issued.append(id) }
				FileUrl(id, file) => { ..b, pending: b.pending.append({ id, url: "url", body: "", kind: UrlRequest(file) }), issued: b.issued.append(id) }
				PortSend(port, msg) => { ..b, port_log: b.port_log.append({ port, json: msg.json }) }
				PortCall(id, port, msg, timeout_ms) => { ..b, pending: b.pending.append({ id, url: "port", body: "", kind: PortRequest({ port, json: msg.json, timeout_ms }) }), issued: b.issued.append(id) }
				PortListen(id, port, msg) => { ..b, subs: b.subs.append({ id, sub: PortSub(port, msg.json) }), report_sources: if (b.latest_ports.contains(port)) b.report_sources.insert(id, {}) else b.report_sources }
				Fetch(id, method, url, _, _, options) => { ..b, network: b.network.insert(id, { method, options }), report_sources: if (options.progress_ms > 0) b.report_sources.insert(id, {}) else b.report_sources, pending: b.pending.append({ id, url, body: "", kind: FetchRequest }), issued: b.issued.append(id) }
				# The runtime resolves a save's file when it applies the batch,
				# while a handle the batch released still names its file.
				Save(file, name) => { ..b, saves: b.saves.append({ name, bytes: SpecRunner.file_bytes(b, file) }) }
			}
		}
		$b
	}

	## Count only retained non-lossy storage failures; storage reads and copies
	## already have the in-flight table's separate bound.
	failure_tasks : Browser -> U64
	failure_tasks = |browser| browser.failure_queue.len()

	## The one failure timer is a task source beside individual read and copy
	## tasks. A callback's current recipients remain separate from its next task.
	callbacks_waiting : Browser -> Bool
	callbacks_waiting = |browser| !browser.gets.is_empty() or browser.failure_active

	## Containment forgets every scheduled answer while retaining the last guard.
	clear_callbacks : Browser -> Browser
	clear_callbacks = |browser| { ..browser, gets: [], failure_queue: [], failure_scheduled: False, failure_active: False }

	## A write persists atomically or records an occurrence for each subscriber
	## present at failure. Removal ignores quota, as the browser does.
	storage_write : Browser, { capacity : U64, session : Bool, key : Str, value : [Absent, Present(Str)] } -> Browser
	storage_write = |browser, { capacity, session, key, value }| {
		available = if (session) browser.env.session_available else browser.env.storage_available
		full = if (session) browser.settings.session_full else browser.settings.local_full
		fails = !available or (full and value != Absent)
		if fails {
			payload = [25, if (session) 2 else 1, if (available) 1 else 2].concat(key.to_utf8())
			answers = browser.subs.keep_if(|sub| sub.sub == StorageFailures).map(|sub| { id: sub.id, payload, ready: False })
			if SpecRunner.failure_tasks(browser) + answers.len() > capacity {
				{ ..browser, deferred_error: "resource_limit: storage failure recipients and ingress exceed 4096" }
			} else { ..browser, failure_queue: browser.failure_queue.concat(answers), gets: if (browser.failure_scheduled or answers.is_empty()) browser.gets else browser.gets.append(Failures), failure_scheduled: browser.failure_scheduled or !answers.is_empty() }
		} else {
			pairs = if (session) browser.env.session else browser.env.storage
			next = match value {
				Absent => pairs.keep_if(|(name, _)| name != key)
				Present(text) => SpecRunner.set_store(pairs, key, text)
			}
			{ ..browser, env: if (session) { ..browser.env, session: next } else { ..browser.env, storage: next } }
		}
	}

	## Model one genuine other-document write. The event's value is fixed now;
	## delivery through broadcast uses the ordinary replaceable report source.
	storage_elsewhere : Program(state), S(state), { key : [Absent, Present(Str)], value : [Absent, Present(Str)] } -> Try(S(state), Str)
	storage_elsewhere = |program, state, { key, value }| {
		b = state.browser
		pairs = b.env.storage
		changed = match key {
			Absent => !pairs.is_empty()
			Present(name) => match value {
				Absent => pairs.any(|(k, _)| k == name)
				Present(text) => pairs.find_first(|(k, _)| k == name).map_ok(|(_, prior)| prior != text) ?? True
			}
		}
		if !changed {
			return Ok(state)
		}
		next = match key {
			Absent => []
			Present(name) => match value {
				Absent => pairs.keep_if(|(k, _)| k != name)
				Present(text) => SpecRunner.set_store(pairs, name, text)
			}
		}
		# The unavailable fixture removes the storage getter itself. A real event
		# still changes the other document's store, but no local area identity is
		# available to classify it for this instance.
		if !b.env.storage_available {
			return Ok({ ..state, browser: { ..b, env: { ..b.env, storage: next } } })
		}
		payload = match value {
			Absent => [4]
			Present(text) => [3].concat(text.to_utf8())
		}
		Ok(
			SpecRunner.broadcast(
				program,
				{ ..state, browser: { ..b, env: { ..b.env, storage: next } } },
				|subscription| match subscription.sub {
					StorageSub(name) => key == Absent or key == Present(name)
					_ => False
				},
				payload,
			),
		)
	}

	## Mount the app with the spec's setup.
	start : Program(state), Scm.Spec -> Try(S(state), Str)
	start = |program, spec| {
		if program.version != Dom.protocol_version {
			return Err("the program speaks protocol ${program.version.to_str()}; this runner decodes ${Dom.protocol_version.to_str()}")
		}
		var $files = []
		var $max_output = SpecRunner.max_output_bytes
		var $settings = (SpecRunner.fresh_browser({})).settings
		for entry in spec.setup {
			match entry.item {
				File({ name, mime, text, repeat }) => {
					if $files.any(|f| f.name == name) {
						return Err("file \"${name}\" is declared twice")
					}
					$files = $files.append({ name, mime, bytes: List.repeat(text.to_utf8(), repeat).join() })
				}
				MaxOutputBytes(n) => {
					$max_output = n
				}
				LocalStorageFull => {
					$settings = { ..$settings, local_full: True }
				}
				SessionStorageFull => {
					$settings = { ..$settings, session_full: True }
				}
				ClipboardDenied => {
					$settings = { ..$settings, clipboard_denied: True }
				}
				MaxPasteBytes(max_paste) => {
					$settings = { ..$settings, max_paste }
				}
				SessionStorage(_) | SessionStorageUnavailable | InitialLocation(_) | LocalStorage(_) | InitialOnline(_) | InitialVisibility(_) | InitialMedia(_) | InitialTime(_) | Seed(_) | Languages(_) | TimeZone(_) | LocalStorageUnavailable => {}
			}
		}
		queries = SpecRunner.decode_declarations((program.keys)()).media
		for (query, _) in spec.environment.media {
			if !queries.contains(query) {
				return Err("initial-media query ${JsonOut.quote(query)} is not declared")
			}
		}
		s0 = SpecRunner.mount_config(program, spec.environment, $settings)
		b0 = s0.browser
		Ok({ ..s0, browser: { ..b0, files: $files, max_output: $max_output } })
	}

	## Mount the app at `url` with `storage` as local storage; the app's
	## declared keys that hold a value become its boot storage.
	mount : Program(state), Str, List({ key : Str, value : Str }) -> S(state)
	mount = |program, url, storage| SpecRunner.mount_in(program, { url, storage: storage.map(|kv| (kv.key, kv.value)) })

	## Mount from facts the parser resolved, selecting only storage keys the
	## program declared. The browser retains all storage for later requests.
	mount_in : Program(state), Scm.Environment -> S(state)
	mount_in = |program, env| SpecRunner.mount_config(program, env, (SpecRunner.fresh_browser({})).settings)

	## Install fixture service behavior before mount emits any storage command.
	mount_config : Program(state), Scm.Environment, { local_full : Bool, session_full : Bool, clipboard_denied : Bool, max_paste : U64 } -> S(state)
	mount_config = |program, env, settings| {
		declared = SpecRunner.decode_declarations((program.keys)())
		boot_kvs = declared.keys.keep_oks(|key| env.storage.find_first(|(name, _)| name == key))
		boot_session = declared.session_keys.keep_oks(|key| env.session.find_first(|(name, _)| name == key))
		for (query, _) in env.media {
			if !declared.media.contains(query) {
				crash "contract: initial-media query ${JsonOut.quote(query)} is not declared"
			}
		}
		media = declared.media.map(|query| (query, env.media.find_first(|(name, _)| name == query).map_ok(|(_, matches)| matches) ?? False))
		(inst, cmds, wbuf) = (program.init)(SpecRunner.encode_boot({ ..env, media, storage: if (env.storage_available) boot_kvs else [], session: if (env.session_available) boot_session else [] }))
		browser = { ..SpecRunner.fresh_browser({ ..env, media }), latest_ports: declared.latest_ports, settings }
		s0 = SpecRunner.fresh(inst, browser)
		{ ..SpecRunner.drain_focus(program, SpecRunner.answer_gets(program, SpecRunner.take({ ..s0, draining: Bool.True }, inst, cmds, wbuf))), draining: Bool.False }
	}

	## Dispatch event `ev` with `payload` from DOM node index `i`, as the
	## runtime's delegated listener does.
	fire : Program(state), S(state), U64, Str, Str -> Try(S(state), Str)
	fire = |program, s, i, ev, payload|
		if !SpecRunner.attached(s.dom, i) {
			Err("event target is detached")
		} else match Dom.target(s.dom, i, ev, Bool.True) {
			Err(_) => Err("no ${ev} handler")
			Ok(target) => if (target.kind == 1) Ok(SpecRunner.send(program, s, target.node, target.handler, payload.to_utf8())) else Ok(s)
		}

	## Dispatch `ev` if a handler listens for it on the way up from node `i`.
	fire_if : Program(state), S(state), U64, Str, Str -> S(state)
	fire_if = |program, s, i, ev, payload| if (SpecRunner.attached(s.dom, i)) SpecRunner.fire(program, s, i, ev, payload) ?? s else s

	## One host call, then the storage reads and focus events it issued, each
	## answered in a turn of its own as the runtime answers them. Reentrant
	## focus callbacks wait until all of their batch's effects have landed.
	send : Program(state), S(state), U32, U32, List(U8) -> S(state)
	send = |program, s, node, h, payload| {
		if s.fault != Healthy {
			return s
		}
		if s.applying_focus or !s.event_queue.is_empty() {
			input = { node, handler: h, payload, owner: if (node == SpecRunner.fx_node) 0 else Dom.lookup(s.dom, node), source: Occurrence }
			if s.event_queue.len() + SpecRunner.failure_tasks(s.browser) >= 4096 {
				if s.applying_focus or s.draining {
					return { ..s, fault: Poisoned("resource_limit: more than 4096 events queued behind one batch (an event feedback loop)"), event_queue: [], after_batch: [], browser: SpecRunner.clear_callbacks(s.browser) }
				}
				# Free one slot without delivering: the occurrence must pin the
				# remaining reports before the oldest turn can raise callbacks.
				{ input: oldest, rest } = SpecRunner.pop_input(s)
				b = rest.browser
				queued = { ..rest, draining: Bool.True, turns: 0, event_queue: rest.event_queue.append(input), browser: { ..b, reports: { ..b.reports, epoch: b.reports.epoch + 1 } } }
				active = SpecRunner.deliver_input(program, { state: queued, input: oldest })
				return SpecRunner.release_reports(program, { ..active, draining: Bool.False })
			}
			b = s.browser
			queued = { ..s, browser: { ..b, reports: { ..b.reports, epoch: b.reports.epoch + 1 } }, event_queue: s.event_queue.append(input) }
			return if (s.applying_focus or s.draining) queued else SpecRunner.drain_focus(program, queued)
		}
		SpecRunner.send_now(program, { state: s, node: node, handler: h, payload: payload })
	}

	## Run an entry already selected for delivery, without queuing it again.
	## Its batch's focus and storage callbacks still pass through ingress.
	send_now : Program(state), { state : S(state), node : U32, handler : U32, payload : List(U8) } -> S(state)
	send_now = |program, { state: s, node, handler: h, payload }| {
		outer = !s.draining
		active = if (outer) { ..s, draining: Bool.True, turns: 0 } else s
		if !outer and active.turns >= 4096 {
			return { ..active, fault: Poisoned("resource_limit: more than 4096 turns delivered without returning to idle (an event feedback loop)"), event_queue: [], after_batch: [], browser: SpecRunner.clear_callbacks(active.browser) }
		}
		is_final_network = node == SpecRunner.fx_node and payload.first() != Ok(26) and active.browser.network.contains(h)
		cleaned = if (is_final_network) { ..active, browser: { ..active.browser, report_sources: active.browser.report_sources.remove(h), network: active.browser.network.remove(h), reports: { ..active.browser.reports, index: active.browser.reports.index.remove(Request(h)) } } } else active
		counted = { ..cleaned, turns: cleaned.turns + if (outer) 0 else 1 }
		(inst, cmds, wbuf) = (program.event)(counted.inst, counted.buf, counted.wbuf, node, h, payload)
		next = SpecRunner.answer_gets(program, SpecRunner.take(counted, inst, cmds, wbuf))
		if (outer) { ..SpecRunner.drain_focus(program, next), draining: Bool.False } else next
	}

	## Apply deferred effects, showing values and reference commands in stream order.
	## Their synchronous callbacks retain their routes and join ordinary ingress,
	## so no callback observes a partly applied command batch.
	drain_focus : Program(state), S(state) -> S(state)
	drain_focus = |program, s0| {
		var $s = { ..s0, draining: Bool.True }
		while $s.fault == Healthy and (!$s.after_batch.is_empty() or !$s.event_queue.is_empty() or SpecRunner.callbacks_waiting($s.browser)) {
			if SpecRunner.callbacks_waiting($s.browser) and !$s.event_queue.is_empty() and !SpecRunner.head_ready($s) {
				b = $s.browser
				$s = { ..$s, browser: { ..b, reports: { ..b.reports, epoch: b.reports.epoch + 1 } } }
			}
			while $s.fault == Healthy and !$s.after_batch.is_empty() {
				command = $s.after_batch.first() ?? crash "SpecRunner.drain_focus: not empty"
				s = { ..$s, applying_focus: Bool.True, after_batch: $s.after_batch.drop_first(1) }
				applied = match command {
					Effect(fx) => {
						browser = SpecRunner.absorb_limit(s.browser, [fx], 4096 - s.event_queue.len())
						if (browser.deferred_error.is_empty()) { ..s, browser } else { ..s, browser: SpecRunner.clear_callbacks(browser), fault: Poisoned(browser.deferred_error), event_queue: [], after_batch: [] }
					}
					Show(show) => if (SpecRunner.attached(s.dom, show.target) and (if (show.property == 6) Dom.node(s.dom, show.target).shown_intent.dialog else Dom.node(s.dom, show.target).shown_intent.popover) == show.intent) SpecRunner.change_shown(s, show.target, show.value) else s
					Ref(ref) => {
						i = ref.target
						live = SpecRunner.attached(s.dom, i) and (s.dom.statics.get(ref.node.to_u64()) ?? 0).bitwise_and(1099511627775) == i + 1
						if !live {
							s
						} else match ref.action {
							Focus(4) => { ..s, dom: Dom.apply_value(s.dom, i, ref.node), deferred: if (s.focused == i + 1) NoValue else s.deferred }
							Focus(2) => if (s.focused == i + 1) SpecRunner.move_focus(program, s, 0) else s
							Focus(_) => if (SpecRunner.focusable_in(s.dom, i) and SpecRunner.reachable(s, i)) SpecRunner.move_focus(program, s, i + 1) else s
							IntoView(_) | To(_) => SpecRunner.perform_scroll(program, s, i, ref.action)
						}
					}
				}
				$s = { ..applied, applying_focus: Bool.False }
			}
			if !$s.event_queue.is_empty() and SpecRunner.head_ready($s) {
				{ input, rest } = SpecRunner.pop_input($s)
				$s = SpecRunner.deliver_input(program, { state: rest, input: input })
			} else if SpecRunner.callbacks_waiting($s.browser) {
				$s = SpecRunner.answer_gets(program, $s)
			} else {
				break
			}
		}
		b = $s.browser
		if $s.event_queue.is_empty() {
			{ ..$s, draining: s0.draining, browser: { ..b, reports: { ..b.reports, head: 0, index: Dict.empty() } } }
		} else { ..$s, draining: s0.draining }
	}

	## Pop exactly one ingress slot and remove only the index that still
	## names it. A later report from a pinned source has its own slot.
	pop_input : S(state) -> { input : Input, rest : S(state) }
	pop_input = |s| {
		input = s.event_queue.first() ?? crash "SpecRunner.pop_input: queue is not empty"
		b = s.browser
		reports = b.reports
		index = match input.source {
			Report(id) => match reports.index.get(id) {
				Ok(position) if position.slot == reports.head => reports.index.remove(id)
				_ => reports.index
			}
			Occurrence => reports.index
		}
		{ input, rest: { ..s, event_queue: s.event_queue.drop_first(1), browser: { ..b, reports: { ..reports, head: reports.head + 1, index } } } }
	}

	## An unpinned report waits for a frame. The source index identifies its
	## current epoch and absolute slot without searching later queue entries.
	head_ready : S(state) -> Bool
	head_ready = |s| {
		if s.browser.reports.releasing {
			return True
		}
		input = s.event_queue.first() ?? return False
		match input.source {
			Occurrence => True
			Report(source) => match s.browser.reports.index.get(source) {
				Ok(at) => at.epoch != s.browser.reports.epoch or at.slot != s.browser.reports.head
				Err(_) => True
			}
		}
	}

	## A cancelled source or a DOM lifetime that ended cannot receive its
	## queued input. Valid entries use the same ordinary turn path.
	deliver_input : Program(state), { state : S(state), input : Input } -> S(state)
	deliver_input = |program, { state: s, input }| {
		live = match input.source {
			Report(Request(id)) => s.browser.report_sources.contains(id)
			Report(Pointer({ element, .. })) | Report(Scroll({ element, .. })) => SpecRunner.attached(s.dom, element) and (s.dom.statics.get(input.node.to_u64()) ?? 0).bitwise_and(1099511627775) == input.owner + 1
			Report(Observation({ element, kind })) => SpecRunner.attached(s.dom, element) and Dom.node(s.dom, element).observing.bitwise_and(if (kind == 7) 1 else 2) != 0 and (s.dom.statics.get(input.node.to_u64()) ?? 0).bitwise_and(1099511627775) == input.owner + 1
			Occurrence => {
				current = (s.dom.statics.get(input.node.to_u64()) ?? 0).bitwise_and(1099511627775)
				input.node == SpecRunner.fx_node or (current == input.owner + 1 and SpecRunner.attached(s.dom, input.owner))
			}
		}
		if (live) SpecRunner.send_now(program, { state: s, node: input.node, handler: input.handler, payload: input.payload }) else s
	}

	## Queue a frozen report, replacing only its source's entry in this
	## epoch. A full idle queue drains early instead of refusing data-sized
	## source sets; occurrences use the same queue and pin by advancing it.
	report : Program(state), { state : S(state), id : U32, payload : List(U8) } -> S(state)
	report = |program, { state: s, id, payload }| {
		if !s.browser.report_sources.contains(id) {
			return s
		}
		SpecRunner.queue_report(program, { state: s, source: Request(id), node: SpecRunner.fx_node, handler: id, owner: 0, payload })
	}

	## All report kinds use one queue and epoch. DOM identity is the declaring
	## node index, which is never recycled by the oracle.
	queue_report : Program(state), { state : S(state), source : ReportSource, node : U32, handler : U32, owner : U64, payload : List(U8) } -> S(state)
	queue_report = |program, { state: s, source, node, handler, owner, payload }| {
		is_live = match source {
			Request(id) => s.browser.report_sources.contains(id)
			Pointer({ element, .. }) | Scroll({ element, .. }) => SpecRunner.attached(s.dom, element) and (s.dom.statics.get(node.to_u64()) ?? 0).bitwise_and(1099511627775) == owner + 1
			Observation({ element, kind }) => SpecRunner.attached(s.dom, element) and Dom.node(s.dom, element).observing.bitwise_and(if (kind == 7) 1 else 2) != 0 and (s.dom.statics.get(node.to_u64()) ?? 0).bitwise_and(1099511627775) == owner + 1
		}
		if s.fault != Healthy or !is_live {
			return s
		}
		b = s.browser
		reports = b.reports
		match reports.index.get(source) {
			Ok(position) if position.epoch == reports.epoch => {
				at = position.slot - reports.head
				prior = s.event_queue.get(at) ?? crash "SpecRunner.report: index names a queued report"
				{ list, .. } = s.event_queue.replace(at, { ..prior, payload }) ?? crash "SpecRunner.report: queued slot exists"
				return { ..s, event_queue: list, browser: { ..b, reports: { ..reports, replaced: reports.replaced + 1 } } }
			}
			_ => {}
		}
		if s.event_queue.len() + SpecRunner.failure_tasks(s.browser) >= 4096 {
			if s.applying_focus or s.draining {
				return { ..s, fault: Poisoned("resource_limit: more than 4096 events queued behind one batch (an event feedback loop)"), event_queue: [], after_batch: [], browser: { ..SpecRunner.clear_callbacks(b), reports: { ..reports, head: 0, index: Dict.empty() } } }
			}
			return SpecRunner.queue_report(program, { state: SpecRunner.release_reports(program, s), source, node, handler, owner, payload })
		}
		slot = reports.head + s.event_queue.len()
		{ ..s, event_queue: s.event_queue.append({ node, handler, payload, owner, source: Report(source) }), browser: { ..b, reports: { ..reports, index: reports.index.insert(source, { epoch: reports.epoch, slot }) } } }
	}

	## Deliver the waiting ingress entries as ordinary turns. A held frame
	## remains held after an occurrence drains it.
	release_reports : Program(state), S(state) -> S(state)
	release_reports = |program, s| {
		b = s.browser
		released = SpecRunner.drain_focus(program, { ..s, turns: 0, browser: { ..b, reports: { ..b.reports, epoch: b.reports.epoch + 1, releasing: True } } })
		{ ..released, browser: { ..released.browser, reports: { ..released.browser.reports, releasing: b.reports.releasing } } }
	}

	## Answer every storage read waiting for its turn: the stored value, or
	## `Missing` when there is none or storage is unavailable.
	answer_gets : Program(state), S(state) -> S(state)
	answer_gets = |program, s0| {
		var $s = s0
		while $s.fault == Healthy and SpecRunner.callbacks_waiting($s.browser) and $s.event_queue.is_empty() and $s.after_batch.is_empty() {
			b = $s.browser
			if b.failure_active {
				match b.failure_queue.first() {
					Ok(recipient) if recipient.ready => {
						next = { ..$s, browser: { ..b, failure_queue: b.failure_queue.drop_first(1) } }
						$s = if (b.subs.any(|entry| entry.id == recipient.id and entry.sub == StorageFailures)) SpecRunner.deliver(program, next, recipient.id, recipient.payload) else next
					}
					_ => {
						$s = { ..$s, browser: { ..b, failure_active: False } }
					}
				}
			} else {
				task = b.gets.first() ?? crash "SpecRunner.answer_gets: a callback is pending"
				next = { ..$s, browser: { ..b, gets: b.gets.drop_first(1) } }
				$s = match task {
					Read({ id, key, session }) => {
						available = if (session) b.env.session_available else b.env.storage_available
						pairs = if (session) b.env.session else b.env.storage
						found = if (available) pairs.find_first(|(name, _)| name == key) else Err(NotFound)
						payload = match found {
							Ok((_, value)) => [3].concat(value.to_utf8())
							Err(_) => [4]
						}
						SpecRunner.deliver(program, next, id, payload)
					}
					Answer({ id, payload, scoped }) => if (!scoped or b.subs.any(|entry| entry.id == id)) SpecRunner.deliver(program, next, id, payload) else next
					Failures => { ..next, browser: { ..next.browser, failure_scheduled: False, failure_active: True, failure_queue: b.failure_queue.map(|entry| { ..entry, ready: True }) } }
				}
			}
		}
		$s
	}

	## Deliver an effect result to request `id`.
	deliver : Program(state), S(state), U32, List(U8) -> S(state)
	deliver = |program, s, id, payload| {
		ready = if (payload == [7]) { ..s, browser: { ..s.browser, report_sources: s.browser.report_sources.remove(id), reports: { ..s.browser.reports, index: s.browser.reports.index.remove(Request(id)) } } } else s
		SpecRunner.send(program, ready, SpecRunner.fx_node, id, payload)
	}

	## Deliver `payload` to every live subscription `pick` selects.
	broadcast : Program(state), S(state), ({ id : U32, sub : Sub } -> Bool), List(U8) -> S(state)
	broadcast = |program, s0, pick, payload| {
		var $s = s0
		for x in s0.browser.subs.keep_if(pick) {
			is_report = match x.sub {
				OnlineSub | VisibilitySub | MediaSub(_) | StorageSub(_) => Bool.True
				PortSub(port, _) => s0.browser.latest_ports.contains(port)
				_ => Bool.False
			}
			$s = if (is_report) SpecRunner.report(program, { state: $s, id: x.id, payload: payload }) else SpecRunner.deliver(program, SpecRunner.release_reports(program, $s), x.id, payload)
		}
		$s
	}

	## The browser moved to `browser.env.url` on its own: every popstate
	## subscription hears it.
	popstate : Program(state), S(state) -> S(state)
	popstate = |program, s| SpecRunner.broadcast(program, s, |x| x.sub == Pop, SpecRunner.encode_location(s.browser.env.url))

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
			TimerRequest => return Ok(SpecRunner.deliver(program, { ..s, browser: { ..b, pending: rest } }, id, SpecRunner.put_u64([5], b.env.now_ms.to_u64_wrap())))
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
	tick = |program, s, ms| SpecRunner.broadcast(program, s, |x| x.sub == Interval(ms.to_u32_wrap()), SpecRunner.put_u64([5], s.browser.env.now_ms.to_u64_wrap()))

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
		editable = Dom.has_attr(n, "contenteditable") and ["", "true", "plaintext-only"].contains(Dom.enum_attr(n, "contenteditable"))
		(SpecRunner.intrinsic_focusable(n) or editable) and !SpecRunner.disabled(n) and !SpecRunner.flag_on(n, "hidden") and !(n.tag == "input" and Dom.enum_attr(n, "type") == "hidden")
	}

	## Native controls, links and tabindex retain focus independently of an
	## editable ancestor; other editable nodes focus only as editing hosts.
	intrinsic_focusable : Dom.DNode -> Bool
	intrinsic_focusable = |n| n.tag == "button" or n.tag == "input" or n.tag == "select" or n.tag == "textarea" or (n.tag == "a" and Dom.has_attr(n, "href")) or Dom.has_attr(n, "tabindex")

	## Focus cannot enter a detached or hidden subtree. The oracle checks
	## declared HTML attributes; CSS layout remains the browser's domain.
	focusable_in : Dom.Model, U64 -> Bool
	focusable_in = |dom, i| {
		target = Dom.node(dom, i)
		if !SpecRunner.focusable(target) {
			return Bool.False
		}
		if !SpecRunner.intrinsic_focusable(target) and target.parent != 0 and Dom.content_editable(dom, target.parent - 1) {
			return Bool.False
		}
		var $at = i
		while True {
			n = Dom.node(dom, $at)
			if SpecRunner.flag_on(n, "hidden") or ((n.tag == "dialog" or Dom.has_attr(n, "popover")) and n.shown == Hidden) {
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
		if s0.applying_focus {
			return SpecRunner.queue_focus(s0, to)
		}
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

	## Browser state uses parent paths and modal lifetimes, independent of engine sites.
	inside : Dom.Model, U64, U64 -> Bool
	inside = |dom, i, ancestor| {
		var $at = i + 1
		while $at != 0 {
			if $at == ancestor + 1 {
				return True
			}
			$at = Dom.node(dom, $at - 1).parent
		}
		False
	}

	## Native actions reject only browser reachability facts the oracle models.
	reachable : S(state), U64 -> Bool
	reachable = |s, i| {
		var $at = i + 1
		while $at != 0 {
			n = Dom.node(s.dom, $at - 1)
			if SpecRunner.flag_on(n, "hidden") or ((n.tag == "dialog" or Dom.has_attr(n, "popover")) and n.shown == Hidden) {
				return False
			}
			$at = n.parent
		}
		modal = s.browser.top_layer.find_last(|index| Dom.node(s.dom, index).shown == Modal)
		match modal {
			Ok(index) => SpecRunner.inside(s.dom, i, index)
			Err(_) => True
		}
	}

	## Freeze non-bubbling focus callbacks while a batch is still being applied.
	queue_event : S(state), U64, Str, Str -> S(state)
	queue_event = |s, i, event, payload| {
		if !SpecRunner.attached(s.dom, i) {
			return s
		}
		match Dom.target(s.dom, i, event, False) {
			Ok(target) if target.kind == 1 and s.event_queue.len() + SpecRunner.failure_tasks(s.browser) >= 4096 => { ..s, fault: Poisoned("resource_limit: more than 4096 events queued behind one batch (an event feedback loop)"), event_queue: [], after_batch: [], browser: SpecRunner.clear_callbacks(s.browser) }
			Ok(target) if target.kind == 1 => {
				b = s.browser
				{ ..s, event_queue: s.event_queue.append({ node: target.node, handler: target.handler, payload: payload.to_utf8(), owner: Dom.lookup(s.dom, target.node), source: Occurrence }), browser: { ..b, reports: { ..b.reports, epoch: b.reports.epoch + 1 } } }
			}
			_ => s
		}
	}

	## Focus restoration must happen while a closing dialog's contents still exist.
	queue_focus : S(state), U64 -> S(state)
	queue_focus = |s, to| {
		if s.focused == to {
			return s
		}
		from = s.focused
		changed = if from != 0 and SpecRunner.text_control(Dom.node(s.dom, from - 1)) and SpecRunner.value_of(s.dom, from - 1) != s.focus_value {
			SpecRunner.queue_event(s, from - 1, "change", SpecRunner.value_of(s.dom, from - 1))
		} else s
		landed = match changed.deferred {
			Held(value) if from != 0 => { ..changed, dom: Dom.set_live_on(changed.dom, from - 1, "value", value) }
			_ => changed
		}
		moved = { ..landed, focused: to, deferred: NoValue, focus_value: if (to == 0) "" else SpecRunner.value_of(landed.dom, to - 1) }
		blurred = if (from == 0) moved else SpecRunner.queue_event(moved, from - 1, "blur", SpecRunner.value_of(moved.dom, from - 1))
		if (to == 0) blurred else SpecRunner.queue_event(blurred, to - 1, "focus", SpecRunner.value_of(blurred.dom, to - 1))
	}

	## Appending native task observations never wraps a slot or poisons the app.
	queue_ui : S(state), UiTask -> S(state)
	queue_ui = |s, task| {
		b = s.browser
		if b.ui_exhausted {
			return s
		}
		if b.ui_head > 18446744073709551615 - b.ui_tasks.len() {
			return { ..s, browser: { ..b, ui_exhausted: True } }
		}
		{ ..s, browser: { ..b, ui_tasks: b.ui_tasks.append(task) } }
	}

	## Replacing a toggle cancels its old task and queues it at the new task position.
	## A direct slot avoids scanning unrelated browser tasks during coalescing.
	queue_toggle : S(state), U64 -> S(state)
	queue_toggle = |s, i| {
		b = s.browser
		n = Dom.node(s.dom, i)
		if b.ui_exhausted {
			return s
		}
		if b.ui_head > 18446744073709551615 - b.ui_tasks.len() {
			return { ..s, browser: { ..b, ui_exhausted: True } }
		}
		slot = b.ui_head + b.ui_tasks.len()
		tasks = if (n.pending_toggle) b.ui_tasks.set(n.toggle_slot - b.ui_head, Cancelled) ?? crash "native toggle task slot" else b.ui_tasks
		marked = { ..s, dom: Dom.modify(s.dom, i, |element| { ..element, pending_toggle: True, toggle_slot: slot }), browser: { ..b, ui_tasks: tasks } }
		SpecRunner.queue_ui(marked, Toggle(i))
	}

	## Native show/close defaults maintain a distinct live top-layer state.
	change_shown : S(state), U64, Dom.Shown -> S(state)
	change_shown = |s0, i, value| SpecRunner.change_shown_with(s0, { target: i, value, focus: Restore })

	## Showing a sibling or modal hides auto popovers without restoring their
	## opener. Native close, Escape and light dismissal retain normal restoration.
	change_shown_with : S(state), { target : U64, value : Dom.Shown, focus : [Restore, Keep] } -> S(state)
	change_shown_with = |s0, { target: i, value, focus }| {
		old = Dom.node(s0.dom, i).shown
		if old == value {
			return s0
		}
		var $s = s0
		if value == Modal or (value == Popover and Dom.enum_attr(Dom.node($s.dom, i), "popover") == "auto") {
			for other in $s.browser.top_layer {
				if other != i and Dom.node($s.dom, other).shown == Popover and Dom.enum_attr(Dom.node($s.dom, other), "popover") == "auto" and !SpecRunner.inside($s.dom, i, other) {
					$s = SpecRunner.change_shown_with($s, { target: other, value: Hidden, focus: Keep })
				}
			}
		}
		# Changing a dialog's display mode closes it before invoking the new method.
		if old != Hidden and value != Hidden {
			$s = SpecRunner.change_shown($s, i, Hidden)
		}
		s = $s
		b = s.browser
		n = Dom.node(s.dom, i)
		attrs = if n.tag == "dialog" {
			if (value == Hidden) n.attrs.keep_if(|(key, _)| key != "open") else n.attrs.keep_if(|(key, _)| key != "open").append(("open", ""))
		} else n.attrs
		dom = Dom.modify(s.dom, i, |current| { ..current, shown: value, attrs })
		changed = { ..s, dom, browser: { ..b, top_layer: if (value == Modal or value == Popover) b.top_layer.keep_if(|other| other != i).append(i) else b.top_layer.keep_if(|other| other != i), openers: if (value == Hidden) b.openers.remove(i) else b.openers.insert(i, s.focused) } }
		queued = SpecRunner.queue_toggle(changed, i)
		if value == Hidden {
			opener = b.openers.get(i) ?? 0
			restored = if focus == Restore and opener != 0 and (old == Modal or (s.focused != 0 and SpecRunner.inside(s.dom, s.focused - 1, i))) and SpecRunner.attached(queued.dom, opener - 1) and SpecRunner.focusable_in(queued.dom, opener - 1) {
				SpecRunner.queue_focus(queued, opener)
			} else if s.focused != 0 and SpecRunner.inside(s.dom, s.focused - 1, i) {
				# Hiding focused content leaves body active when no visible opener
				# is restored, including a modal re-shown after its row moved.
				SpecRunner.queue_focus(queued, 0)
			} else queued
			if n.tag == "dialog" {
				SpecRunner.queue_ui(restored, Close(i))
			} else restored
		} else {
			autofocus = Dom.find(queued.dom, i, |child| Dom.has_attr(child, "autofocus"))
			chosen = match autofocus {
				Ok(target) if SpecRunner.focusable_in(queued.dom, target) => target + 1
				_ if n.tag == "dialog" => SpecRunner.focus_order(queued.dom, i).first().map_ok(|target| target + 1) ?? i + 1
				_ => 0
			}
			if (chosen == 0) queued else SpecRunner.queue_focus(queued, chosen)
		}
	}

	## UI tasks read live state at delivery, then enter the ordinary event path.
	deliver_ui : Program(state), S(state) -> S(state)
	deliver_ui = |program, s| {
		task = s.browser.ui_tasks.first() ?? crash "SpecRunner.deliver_ui: pending task"
		b = s.browser
		rest = b.ui_tasks.drop_first(1)
		next = { ..s, browser: { ..b, ui_tasks: rest, ui_head: if (rest.is_empty()) 0 else b.ui_head + 1 } }
		if task == Cancelled {
			return next
		}
		(index, event) = match task {
			Toggle(i) => (i, "toggle")
			Close(i) => (i, "close")
			Cancelled => crash "native UI task was already skipped"
		}
		cleared = match task {
			Toggle(_) => { ..next, dom: Dom.modify(next.dom, index, |n| { ..n, pending_toggle: False }) }
			Close(_) => next
			Cancelled => crash "native UI task was already skipped"
		}
		if !SpecRunner.attached(cleared.dom, index) {
			return cleared
		}
		match Dom.target(cleared.dom, index, event, False) {
			Ok(target) => {
				payload = if (target.kind == 5) [if (Dom.node(cleared.dom, index).shown == Hidden) 0.U8 else 1] else []
				SpecRunner.send(program, cleared, target.node, target.handler, payload)
			}
			Err(_) => cleared
		}
	}

	## Escape consumes the newest close watcher; cancellation needs fresh activation.
	dismiss_ui : Program(state), S(state) -> S(state)
	dismiss_ui = |program, s| {
		i = s.browser.top_layer.find_last(|target| Dom.node(s.dom, target).shown == Modal or (Dom.node(s.dom, target).shown == Popover and Dom.enum_attr(Dom.node(s.dom, target), "popover") == "auto")) ?? return s
		n = Dom.node(s.dom, i)
		if n.shown == Popover {
			if (Dom.enum_attr(n, "popover") == "auto") SpecRunner.change_shown(s, i, Hidden) else s
		} else if n.shown == Modal {
			prevent = s.browser.cancel_allowed and (Dom.target(s.dom, i, "cancel", False).map_ok(|target| target.policies.bitwise_and(1) != 0) ?? False)
			next = match Dom.target(s.dom, i, "cancel", False) {
				Ok(target) => SpecRunner.send(program, s, target.node, target.handler, [])
				Err(_) => s
			}
			used = { ..next, browser: { ..next.browser, cancel_allowed: False } }
			if (prevent) used else SpecRunner.change_shown(used, i, Hidden)
		} else s
	}

	## Scroll observation is bounded and cannot suppress the performed command.
	record_scroll : S(state), U64, Dom.RefAction -> S(state)
	record_scroll = |s, i, action| {
		b = s.browser
		if b.scroll_exhausted {
			return s
		}
		if b.scroll_count == 18446744073709551615 {
			return { ..s, browser: { ..b, scroll_exhausted: True } }
		}
		ordinal = b.scroll_count + 1
		history = b.scrolls.append({ ordinal, target: i, action })
		{ ..s, browser: { ..b, scroll_count: ordinal, scrolls: if (history.len() > 4096) history.drop_first(1) else history } }
	}

	## Inject a layout observation only while its declared observation is live.
	inject_observation : Program(state), S(state), { loc : Scm.Loc, kind : U8, payload : List(U8) } -> Try(S(state), Str)
	inject_observation = |program, s, { loc, kind, payload }| {
		i = SpecRunner.need(s.dom, loc)?
		bit = if (kind == 7) 1.U8 else 2
		event = if (kind == 7) "size" else "seen"
		if Dom.node(s.dom, i).observing.bitwise_and(bit) == 0 {
			return Err("${Scm.show_loc(loc)} has no live ${event} observation")
		}
		target = Dom.target(s.dom, i, event, False) ? |_| "${Scm.show_loc(loc)} has no ${event} handler"
		Ok(SpecRunner.queue_report(program, { state: s, source: Observation({ element: i, kind }), node: target.node, handler: target.handler, owner: Dom.lookup(s.dom, target.node), payload }))
	}

	## A changed offset raises the element's own scroll event, never an ancestor's.
	set_scroll : Program(state), S(state), { target : U64, top : U32, left : U32 } -> S(state)
	set_scroll = |program, s, { target: i, top, left }| {
		prior = Dom.node(s.dom, i).scroll
		if prior.top == top and prior.left == left {
			return s
		}
		changed = { ..s, dom: Dom.modify(s.dom, i, |n| { ..n, scroll: { top, left } }) }
		handler = Dom.target(changed.dom, i, "scroll", False) ?? return changed
		if handler.kind == 6 {
			SpecRunner.queue_report(program, { state: changed, source: Scroll({ element: i, handler: handler.handler }), node: handler.node, handler: handler.handler, owner: Dom.lookup(changed.dom, handler.node), payload: SpecRunner.put_u32(SpecRunner.put_u32([], top), left) })
		} else SpecRunner.send(program, changed, handler.node, handler.handler, [])
	}

	## Explicit commands keep their observable command record. Handled scrollers
	## additionally model only geometry-free offsets; unsupported placement fails
	## the spec rather than inventing a layout or changing an application's fault.
	perform_scroll : Program(state), S(state), U64, Dom.RefAction -> S(state)
	perform_scroll = |program, s, i, action| {
		recorded = SpecRunner.record_scroll(s, i, action)
		match action {
			To({ top, left, .. }) => {
				if Dom.target(s.dom, i, "scroll", False).is_err() {
					return recorded
				}
				if top == End or left == End {
					return { ..recorded, browser: { ..recorded.browser, scroll_error: "ScrollTo End on an element that handles scroll needs layout; use a scroll step" } }
				}
				prior = Dom.node(s.dom, i).scroll
				edge = |value, before| match value {
					Keep => before
					Start => 0
					Px(pixels) => pixels
					End => crash "SpecRunner.perform_scroll: End refused"
				}
				SpecRunner.set_scroll(program, recorded, { target: i, top: edge(top, prior.top), left: edge(left, prior.left) })
			}
			IntoView(_) => {
				var $at = Dom.node(s.dom, i).parent
				while $at != 0 {
					if Dom.target(s.dom, $at - 1, "scroll", False).is_ok() {
						return { ..recorded, browser: { ..recorded.browser, scroll_error: "ScrollIntoView inside an element that handles scroll needs layout; use a scroll step" } }
					}
					$at = Dom.node(s.dom, $at - 1).parent
				}
				recorded
			}
			Focus(_) => crash "SpecRunner.perform_scroll: focus is not scrolling"
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
			if (Dom.has_attr(n, name)) Ok("") else Err(Absent)
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
		for (counter, op, what) in [(32.U64, 13.U64, "issued"), (36, 14, "cancelled"), (40, 19, "port commands sent"), (41, 21, "properties set"), (42, 22, "row properties set"), (43, 23, "registrations released"), (45, 24, "view transitions"), (46, 25, "leave guard commands")] {
			engine = s.work.counters.get(counter) ?? 0
			oracle = s.ops.get(op) ?? 0
			if engine != oracle {
				return Err("the engine counted ${engine.to_str()} effects ${what} but emitted ${oracle.to_str()} ${Dom.op_name(op.to_u8_wrap())} commands")
			}
		}
		observed = s.work.counters.get(44) ?? 0
		if observed != s.dom.observed_count {
			return Err("the engine counted ${observed.to_str()} live observations, but the oracle holds ${s.dom.observed_count.to_str()}")
		}
		Ok({})
	}

	## The settle check after a step: the engine's pass over every layer must
	## emit nothing, or the step left a reader stale. The diagnostic names the
	## commands that pass emitted and the first element they would change, as
	## the oracle renders it now and after them.
	check_settled : Program(state), S(state) -> Try({}, Str)
	check_settled = |program, s| {
		if !s.browser.scroll_error.is_empty() {
			return Err(s.browser.scroll_error)
		}
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
		match op {
			LeavePage(_) if s.browser.reports.held => return Err("leave-page cannot navigate while reports are held")
			LeavePage(_) if !s.browser.pointers.is_empty() => return Err("leave-page cannot navigate while a pointer is down")
			_ => {}
		}
		activated = SpecRunner.activate_step(s, op)
		ready = if (SpecRunner.is_occurrence(activated, op)) SpecRunner.release_reports(program, activated) else activated
		next = SpecRunner.one_ready(program, ready, op)?
		settled = if (next.browser.reports.held) next else SpecRunner.release_reports(program, next)
		if settled.browser.scroll_error.is_empty() {
			Ok(settled)
		} else {
			Err(settled.browser.scroll_error)
		}
	}

	## Activation policy comes from the same complete grammar table emitted for Chrome.
	activate_step : S(state), Scm.Op -> S(state)
	activate_step = |s, op| {
		grant = match Scm.activation_for(op) {
			Never => False
			Always => True
			WhenClicked => match op {
				Click(loc) => SpecRunner.find(s.dom, loc).map_ok(|i| !SpecRunner.disabled(Dom.node(s.dom, i))) ?? False
				Check(loc) => SpecRunner.find(s.dom, loc).map_ok(|i| Dom.live_value(Dom.node(s.dom, i), "checked") != "true") ?? False
				Uncheck(loc) => SpecRunner.find(s.dom, loc).map_ok(|i| Dom.live_value(Dom.node(s.dom, i), "checked") == "true") ?? False
				_ => crash "activation table: clicked policy requires check or uncheck"
			}
			WhenTyped => match op {
				Fill(_, value) => value != ""
				_ => crash "activation table: typed policy requires fill"
			}
			KeyboardPress => match op {
				Press(press) => press.key.key != "Escape"
				_ => crash "activation table: keyboard policy requires press"
			}
			PointerPress => match op {
				PointerDown(press) => press.kind != Touch
				_ => crash "activation table: pointer-down policy requires pointer-down"
			}
			PointerRelease => match op {
				PointerUp(place) => s.browser.pointers.get(place.id).map_ok(|pointer| pointer.kind == Touch) ?? False
				_ => crash "activation table: pointer-up policy requires pointer-up"
			}
		}
		if (grant) { ..s, browser: { ..s.browser, cancel_allowed: True, sticky_activation: True } } else s
	}

	## Classify only declarations and step meanings. Assertions and fixtures
	## do not flush a held frame, and an unchanged fact raises no report.
	is_occurrence : S(state), Scm.Op -> Bool
	is_occurrence = |s, op| match op {
		RunEffect(n) => match s.browser.stub {
			Staged(Reject({ kind: Timeout, .. })) if n > 0 => match s.browser.issued.get(n - 1) {
				Ok(id) => match s.browser.pending.find_first(|request| request.id == id) {
					Ok(request) => match request.kind {
						HttpRequest | UploadRequest(_) | FetchRequest => False
						_ => True
					}
					Err(_) => True
				}
				Err(_) => True
			}
			_ => True
		}
		Dismiss | Press(_) | Click(_) | RealClick(_) | Focus(_) | Blur(_) | Change(_, _) | SelectOption(_, _) | Submit(_) | Fill(_, _) | Check(_) | Uncheck(_) | ChooseFiles(_, _) | DropFiles(_, _) | PasteFiles(_, _) | LeavePage(_) | LoseWork(_) | TimeOutWork(_) | Navigate(_) | HistoryBack | HistoryForward | TickInterval(_) | TickIntervalIfActive(_) | AnswerPort(_) | ClosePort(_) | FailPort(_) => Bool.True
		PasteText(loc, _) => match SpecRunner.find(s.dom, loc) {
			Err(_) => False
			Ok(node) => match Dom.target(s.dom, node, "paste", True) {
				Ok(target) => target.kind == 1 or target.kind == 9
				Err(_) => False
			}
		}
		PointerDown(_) | PointerUp(_) | PointerCancel(_) => Bool.True
		PointerMove(place) => !SpecRunner.paced_move(s, place)
		EmitPort({ port, .. }) => !s.browser.latest_ports.contains(port)
		_ => Bool.False
	}

	## Interpret a step after its occurrence boundary has drained. Keeping
	## this match exhaustive makes every parser extension visible here.
	one_ready : Program(state), S(state), Scm.Op -> Try(S(state), Str)
	one_ready = |program, s, op| {
		match op {
			Click(loc) | RealClick(loc) | Fill(loc, _) | Focus(loc) | Blur(loc) | Check(loc) | Uncheck(loc) | SelectOption(loc, _) | Change(loc, _) | Submit(loc) | ChooseFiles(loc, _) | DropFiles(loc, _) | PasteFiles(loc, _) | PasteText(loc, _) => {
				i = SpecRunner.need(s.dom, loc)?
				if !SpecRunner.reachable(s, i) {
					return Err("${Scm.show_loc(loc)} is unreachable: hidden dialog/popover or outside the topmost modal")
				}
			}
			PointerDown(press) => {
				i = SpecRunner.need(s.dom, press.target)?
				if !SpecRunner.reachable(s, i) {
					return Err("pointer target is unreachable: hidden dialog/popover or outside the topmost modal")
				}
			}
			PointerMove(place) | PointerUp(place) => {
				i = SpecRunner.need(s.dom, place.target)?
				if !SpecRunner.reachable(s, i) {
					return Err("pointer target is unreachable: hidden dialog/popover or outside the topmost modal")
				}
			}
			Press({ target: At(loc), .. }) => {
				i = SpecRunner.need(s.dom, loc)?
				if !SpecRunner.reachable(s, i) {
					return Err("press target is unreachable: hidden dialog/popover or outside the topmost modal")
				}
			}
			_ => {}
		}
		dom = s.dom
		b = s.browser
		check = |ok, msg| if (ok) Ok(s) else Err(msg)
		match op {
			Dismiss => SpecRunner.press_key(program, s, { target: Focused, key: { key: "Escape", code: "Escape", ctrl: False, alt: False, shift: False, meta: False } })
			ExpectShown(loc, want) => {
				i = SpecRunner.need(dom, loc)?
				check(Dom.node(dom, i).shown == want, "${Scm.show_loc(loc)} is ${Str.inspect(Dom.node(dom, i).shown)}, expected ${Str.inspect(want)}")
			}
			ExpectTransitions(count) => {
				h = dom.transitions
				if h.exhausted {
					Err("transition observation ordinal exhausted")
				}
				else check(h.count == count, "transition batches performed ${h.count.to_str()}, expected ${count.to_str()}")
			}
			ExpectTransition({ at, types }) => {
				h = dom.transitions
				if h.exhausted {
					return Err("transition observation ordinal exhausted")
				}
				if at > h.count {
					return Err("transition ordinal ${at.to_str()} was not performed")
				}
				record = h.records.get(at) ? |_| "transition ordinal ${at.to_str()} is unavailable in retained history (newest 4096, at most 1048576 encoded type bytes)"
				check(record.types == types, "transition ordinal ${at.to_str()} has types ${Str.inspect(record.types)}, expected ${Str.inspect(types)}")
			}
			ExpectScrolls(count) => {
				if b.scroll_exhausted {
					Err("scroll observation ordinal exhausted")
				}
				else check(b.scroll_count == count, "scroll commands performed ${b.scroll_count.to_str()}, expected ${count.to_str()}")
			}
			ExpectScroll({ ordinal, target, kind }) => {
				if b.scroll_exhausted {
					return Err("scroll observation ordinal exhausted")
				}
				if ordinal <= b.scroll_count and b.scroll_count - ordinal >= 4096 {
					return Err("scroll ordinal ${ordinal.to_str()} is older than retained history (newest 4096)")
				}
				record = b.scrolls.find_first(|r| r.ordinal == ordinal) ? |_| "scroll ordinal ${ordinal.to_str()} was not performed"
				i = SpecRunner.need(dom, target)?
				actual = match record.action {
					IntoView(_) => IntoView
					To(_) => To
					Focus(_) => crash "scroll history contains focus"
				}
				check(record.target == i and actual == kind, "scroll ordinal ${ordinal.to_str()} does not name ${Scm.show_loc(target)} with ${Str.inspect(kind)}")
			}
			Scroll({ target, top, left }) => {
				i = SpecRunner.need(dom, target)?
				Ok(SpecRunner.set_scroll(program, s, { target: i, top, left }))
			}
			ReportSize({ target, width, height }) => SpecRunner.inject_observation(program, s, { loc: target, kind: 7, payload: SpecRunner.put_u32(SpecRunner.put_u32([], width), height) })
			ReportSeen({ target, intersecting, ratio_permille }) => SpecRunner.inject_observation(program, s, { loc: target, kind: 8, payload: [SpecRunner.flag_byte(intersecting), ratio_permille.bitwise_and(255).to_u8_wrap(), ratio_permille.shr_zf_wrap(8).to_u8_wrap()] })
			SetMedia({ query, matches: is_match }) => {
				previous = b.env.media.find_first(|(name, _)| name == query) ? |_| "set-media query ${JsonOut.quote(query)} is not declared"
				if previous.1 == is_match {
					Ok(s)
				} else {
					changed = { ..s, browser: { ..b, env: { ..b.env, media: b.env.media.map(|(name, old)| (name, if (name == query) is_match else old)) } } }
					Ok(SpecRunner.broadcast(program, changed, |sub| sub.sub == MediaSub(query), [22, SpecRunner.flag_byte(is_match)]))
				}
			}
			ExpectObserved(count) => check(dom.observed_count == count and (s.work.counters.get(44) ?? 0) == count, "${dom.observed_count.to_str()} live observations, expected ${count.to_str()}")
			ExpectMediaSubscriptions({ query, count }) => {
				if !b.env.media.any(|(name, _)| name == query) {
					return Err("expect-media-subscriptions query ${JsonOut.quote(query)} is not declared")
				}
				got = b.subs.count_if(|sub| sub.sub == MediaSub(query))
				check(got == count, "${got.to_str()} live media subscriptions for ${JsonOut.quote(query)}, expected ${count.to_str()}")
			}
			HoldReports => if (b.reports.held) Err("hold-reports while reports are already held") else Ok({ ..s, browser: { ..b, reports: { ..b.reports, held: Bool.True } } })
			ReleaseReports => if (!b.reports.held) Err("release-reports while reports are not held") else Ok(SpecRunner.release_reports(program, { ..s, browser: { ..b, reports: { ..b.reports, held: Bool.False } } }))
			ExpectReportsReplaced(count) => check(b.reports.replaced == count, "reports replaced ${b.reports.replaced.to_str()} times, expected ${count.to_str()}")
			PointerDown(press) => SpecRunner.pointer_down(program, s, press)
			PointerMove(place) => SpecRunner.pointer_move(program, s, place)
			PointerUp(place) => SpecRunner.pointer_up(program, s, place)
			PointerCancel(id) => SpecRunner.pointer_cancel(program, s, id)
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
			Press(press) => SpecRunner.press_key(program, s, press)
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
			ExpectLocation(want) => check(b.env.url == want, "location ${JsonOut.quote(b.env.url)}, expected ${JsonOut.quote(want)}")
			ExpectTitle(want) => check(b.title == want, "title ${JsonOut.quote(b.title)}, expected ${JsonOut.quote(want)}")
			ExpectLocalStorage({ key, value }) => {
				got = b.env.storage.find_first(|(name, _)| name == key).map_ok(|(_, stored)| JsonOut.quote(stored)) ?? "<missing>"
				check(got == JsonOut.quote(value), "local storage ${key} = ${got}, expected ${JsonOut.quote(value)}")
			}
			ExpectNoLocalStorage(key) => check(!b.env.storage.any(|(name, _)| name == key), "local storage ${key} is present")
			ExpectPendingEffects(n) => check(b.pending.len() == n, "expected ${n.to_str()} pending effects, got ${b.pending.len().to_str()}")
			RunEffect(n) => SpecRunner.run_effect(program, s, n)
			ExpectRequest({ n, checks }) => {
				if n == 0 {
					return Err("pending request index is one-based")
				}
				request = b.pending.get(n - 1) ? |_| "pending request ${n.to_str()} does not exist"
				network = b.network.get(request.id) ? |_| "pending request ${n.to_str()} is not HTTP, upload or fetch"
				for field in checks {
					actual = match field.key {
						"method" => network.method
						"url" => request.url
						"cache" => network.options.cache
						"credentials" => network.options.credentials
						_ => crash "SpecRunner: parser supplied unknown request field"
					}
					if actual != field.value {
						return Err("request ${n.to_str()} ${field.key}: expected ${JsonOut.quote(field.value)}, got ${JsonOut.quote(actual)}")
					}
				}
				Ok(s)
			}
			ProgressEffect({ n, direction, done, total }) => {
				if n == 0 {
					return Err("pending request index is one-based")
				}
				request = b.pending.get(n - 1) ? |_| "pending request ${n.to_str()} does not exist"
				network = b.network.get(request.id) ? |_| "pending request ${n.to_str()} is not a transfer"
				if network.options.progress_ms == 0 {
					return Err("pending request ${n.to_str()} did not request progress")
				}
				bytes = SpecRunner.put_u64([26, if (direction == Sending) 1 else 2], done)
				payload = match total {
					Unknown => SpecRunner.put_u64(bytes.append(0), 0)
					Known(count) => SpecRunner.put_u64(bytes.append(1), count)
				}
				Ok(SpecRunner.report(program, { state: s, id: request.id, payload }))
			}
			ExpectPortSubscriptionArg({ port, n, json }) => {
				active = b.subs.keep_if(|entry| SpecRunner.on_port(entry.sub, port))
				if n == 0 {
					return Err("active subscription index is one-based")
				}
				entry = active.get(n - 1) ? |_| "active subscription ${n.to_str()} does not exist for ${port}"
				actual = match entry.sub {
					PortSub(_, value) => value
					_ => crash "SpecRunner: selected port subscription changed kind"
				}
				check(actual == json, "active subscription ${n.to_str()} argument differs: ${JsonOut.quote(actual)}")
			}
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
			PasteText(loc, text) => {
				i = SpecRunner.find(s.dom, loc) ? |_| "paste target was not found"
				declaration = match Dom.target(s.dom, i, "paste", True) {
					Ok(target) => target
					Err(_) => return Ok(s)
				}
				if declaration.kind == 9 {
					payload = if (text.count_utf8_bytes() > s.browser.settings.max_paste) [1] else [0].concat(text.to_utf8())
					Ok(SpecRunner.send(program, s, declaration.node, declaration.handler, payload))
				} else if declaration.kind == 1 {
					Ok(SpecRunner.send(program, s, declaration.node, declaration.handler, []))
				} else Ok(s)
			}
			StorageElsewhere({ key, value }) => SpecRunner.storage_elsewhere(program, s, { key: Present(key), value: Present(value) })
			StorageElsewhereRemoved(key) => SpecRunner.storage_elsewhere(program, s, { key: Present(key), value: Absent })
			StorageElsewhereCleared => SpecRunner.storage_elsewhere(program, s, { key: Absent, value: Absent })
			LeavePage({ url, outcome }) => {
				if SpecRunner.same_document(s.browser.env.url, url) {
					return Err("leave-page requires a different document")
				}
				asks = s.browser.guard and s.browser.sticky_activation
				if asks {
					match outcome {
						Stay => Ok(s)
						Leave => SpecRunner.navigate(program, { ..s, browser: { ..s.browser, guard: False } }, url)
						Unasked => Err("leave-page expected no question but the guard asks")
					}
				} else if (outcome == Unasked) SpecRunner.navigate(program, s, url) else Err("leave-page expected a question but the browser does not ask")
			}
			ExpectSessionStorage({ key, value }) => {
				found = s.browser.env.session.find_first(|(name, _)| name == key).map_ok(|(_, text)| text)
				if (found == Ok(value)) Ok(s) else Err("session storage ${JsonOut.quote(key)} differs: ${Str.inspect(found)}")
			}
			ExpectNoSessionStorage(key) => if (s.browser.env.session.any(|(name, _)| name == key)) Err("session storage ${JsonOut.quote(key)} unexpectedly has a value") else Ok(s)
			ExpectClipboard(text) => if (s.browser.clipboard.exhausted) Err("clipboard observation ordinal exhausted") else if (s.browser.clipboard.text == text) Ok(s) else Err("clipboard text differs")
			ExpectClipboardHtml(html) => if (s.browser.clipboard.exhausted) Err("clipboard observation ordinal exhausted") else if (s.browser.clipboard.html == html) Ok(s) else Err("clipboard HTML differs")
			ExpectClipboardWrites(count) => if (s.browser.clipboard.exhausted) Err("clipboard observation ordinal exhausted") else if (s.browser.clipboard.writes == count) Ok(s) else Err("clipboard write count differs: ${s.browser.clipboard.writes.to_str()}")
			Navigate(url) => SpecRunner.navigate(program, s, url)
			HistoryBack =>
				match b.back.last() {
					Ok(prev) if prev.doc != b.doc => Err("history-back crosses documents, which specs do not model")
					Ok(prev) => Ok(SpecRunner.popstate(program, { ..s, browser: { ..b, back: b.back.drop_last(1), fwd: [{ url: b.env.url, doc: b.doc }].concat(b.fwd), env: { ..b.env, url: prev.url } } }))
					Err(_) => Err("history-back with no history")
				}
			HistoryForward =>
				match b.fwd.first() {
					Ok(next) if next.doc != b.doc => Err("history-forward crosses documents, which specs do not model")
					Ok(next) => Ok(SpecRunner.popstate(program, { ..s, browser: { ..b, fwd: b.fwd.drop_first(1), back: b.back.append({ url: b.env.url, doc: b.doc }), env: { ..b.env, url: next.url } } }))
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
			SetTime(now_ms) => Ok({ ..s, browser: { ..b, env: { ..b.env, now_ms } } })
			AdvanceTime(duration) => {
				now_ms = Scm.advance_clock(b.env.now_ms, duration)?
				Ok({ ..s, browser: { ..b, env: { ..b.env, now_ms } } })
			}
			SetOnline(o) => {
				on = o == Online
				if on == b.env.online {
					Ok(s)
				} else {
					s1 = { ..s, browser: { ..b, env: { ..b.env, online: on } } }
					Ok(SpecRunner.broadcast(program, s1, |x| x.sub == OnlineSub, [8, SpecRunner.flag_byte(on)]))
				}
			}
			SetVisibility(v) => {
				vis = v == Visible
				if vis == b.env.visible {
					Ok(s)
				} else {
					s1 = { ..s, browser: { ..b, env: { ..b.env, visible: vis } } }
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
	end_port = |program, initial, port, payload| {
		s = SpecRunner.release_reports(program, initial)
		b = s.browser
		ending = b.subs.keep_if(|x| SpecRunner.on_port(x.sub, port))
		if ending.is_empty() {
			return Err("no live subscription on port ${JsonOut.quote(port)}")
		}
		report_sources = ending.fold(b.report_sources, |sources, sub| sources.remove(sub.id))
		var $s = { ..s, browser: { ..b, subs: b.subs.keep_if(|x| !SpecRunner.on_port(x.sub, port)), report_sources } }
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

	## Deliver one keyboard phase with the entry selected by the rendered map.
	## Prevention is captured before the handler can change that rendered map.
	key_phase : Program(state), S(state), Str, Scm.Key -> (S(state), Bool)
	key_phase = |program, s, event, key| {
		i = if (s.focused == 0) s.dom.root else s.focused - 1
		input = { key: key.key, code: key.code, ctrl: key.ctrl, alt: key.alt, shift: key.shift, meta: key.meta, composing: Bool.False }
		matched = Dom.key_target(s.dom, i, event, input) ?? return (s, Bool.False)
		flags = (if (key.ctrl) 1.U8 else 0).bitwise_or(if (key.alt) 2 else 0).bitwise_or(if (key.shift) 4 else 0).bitwise_or(if (key.meta) 8 else 0)
		heard = matched.heard
		hflags = (if (heard.ctrl) 1.U8 else 0).bitwise_or(if (heard.alt) 2 else 0).bitwise_or(if (heard.shift) 4 else 0).bitwise_or(if (heard.meta) 8 else 0)
		payload = SpecRunner.put_str(SpecRunner.put_str([flags], key.key), key.code).append(hflags)
		(SpecRunner.send(program, s, matched.target.node, matched.target.handler, SpecRunner.put_str(payload, heard.key)), matched.prevent)
	}

	## A refused default comes from Scm's emitted data, shared with Chrome.
	key_unmodelled : Dom.Model, U64, Scm.Key -> Bool
	key_unmodelled = |dom, i, key| {
		n = Dom.node(dom, i)
		kind = Dom.enum_attr(n, "type")
		text = n.tag == "textarea" or (n.tag == "input" and !Scm.key_control_types.text_input_excluded.contains(kind)) or Dom.content_editable(dom, i)
		choice = n.tag == "select" or (n.tag == "input" and Scm.key_control_types.choice_input_types.contains(kind))
		Scm.unmodelled_key_defaults.any(
			|row| {
				applies = (row.control == "text" and text) or (row.control == "textarea" and n.tag == "textarea") or (row.control == "choice" and choice) or (row.control == "link" and n.tag == "a" and Dom.has_attr(n, "href")) or (row.control == "editable" and Dom.content_editable(dom, i))
				applies and row.keys.any(
					|rule| {
						if rule == "printable" {
							key.key.to_utf8().len() == 1 and !key.ctrl and !key.meta
						}
						else if rule.starts_with("modified:") {
							(key.ctrl or key.alt or key.shift or key.meta) and key.key == (Str.from_utf8(rule.to_utf8().drop_first(9)) ?? crash "SpecRunner.key_unmodelled: ASCII rule")
						}
						else if rule.starts_with("primary:") {
							(key.ctrl or key.meta) and Dom.key_label(key.key) == Dom.key_label(Str.from_utf8(rule.to_utf8().drop_first(8)) ?? crash "SpecRunner.key_unmodelled: ASCII rule")
						}
						else rule == key.key
					},
				)
			},
		)
	}

	## DOM order, rather than allocation order, determines sequential focus.
	focus_order : Dom.Model, U64 -> List(U64)
	focus_order = |dom, i| {
		n = Dom.node(dom, i)
		head = if (SpecRunner.focusable_in(dom, i) and !(Dom.attr_of(n, "tabindex").starts_with("-"))) [i] else []
		n.kids.fold(head, |out, child| out.concat(SpecRunner.focus_order(dom, child)))
	}

	## Positive tabindex values precede ordinary DOM order; leaving either
	## end of the sequence focuses the body as Chrome does.
	key_tab : Program(state), S(state), Bool -> S(state)
	key_tab = |program, s, backwards| {
		modal = s.browser.top_layer.find_last(|i| Dom.node(s.dom, i).shown == Modal)
		ordered = SpecRunner.focus_order(s.dom, modal ?? s.dom.root).fold([], |out, i| out.append({ index: i, order: out.len(), tab: U64.from_str(Dom.attr_of(Dom.node(s.dom, i), "tabindex")) ?? 0 })).sort_with(
			|a, b| {
				if a.tab == b.tab {
					if (a.order < b.order) Before else if (a.order > b.order) After else Same
				} else if a.tab == 0 {
					After
				} else if b.tab == 0 {
					Before
				} else if a.tab < b.tab {
					Before
				} else {
					After
				}
			},
		).map(|entry| entry.index)
		if ordered.is_empty() {
			return SpecRunner.move_focus(program, s, 0)
		}
		current = ordered.find_first_index(|i| s.focused == i + 1)
		next = match current {
			Err(_) => if (backwards) ordered.len() - 1 else 0
			Ok(at) => if backwards {
				if (at == 0) ordered.len() else at - 1
			} else {
				at + 1
			}
		}
		SpecRunner.move_focus(program, s, ordered.get(next).map_ok(|i| i + 1) ?? 0)
	}

	## Without a default submit button, HTML submits only when at most one
	## input in the form is of a kind that blocks implicit submission.
	implicit_inputs : Dom.Model, U64 -> U64
	implicit_inputs = |dom, i| {
		n = Dom.node(dom, i)
		own = if (n.tag == "input" and ["", "text", "search", "url", "tel", "email", "password", "date", "month", "week", "time", "datetime-local", "number"].contains(Dom.enum_attr(n, "type"))) 1 else 0
		n.kids.fold(own, |count, child| count + SpecRunner.implicit_inputs(dom, child))
	}

	## Keyboard activation raises click without inventing pointer events, then
	## performs its unprevented control, form or navigation default.
	key_activate : Program(state), S(state), U64 -> Try(S(state), Str)
	key_activate = |program, s, i| {
		if !SpecRunner.attached(s.dom, i) or SpecRunner.disabled(Dom.node(s.dom, i)) {
			return Ok(s)
		}
		prevented = SpecRunner.prevents(s.dom, i, "click")
		next = SpecRunner.fire_if(program, s, i, "click", "")
		if (prevented) Ok(next) else SpecRunner.default_action(program, next, i)
	}

	## A press focuses its optional locator, raises down and up, and models
	## only defaults whose meaning does not need a caret or browser layout.
	Pressed : { key : Scm.Key, document : U64, down_index : U64, activation_path : List({ node : U64, parent : U64, count : U64 }), prevented : Bool }

	## Pure drivers can take both phases when no browser task needs servicing.
	press_key : Program(state), S(state), Scm.KeyPress -> Try(S(state), Str)
	press_key = |program, s, press| {
		(down, context) = SpecRunner.press_down(program, s, press)?
		SpecRunner.press_up(program, down, context)
	}

	## Save only physical press evidence across the browser's intervening tasks.
	press_down : Program(state), S(state), Scm.KeyPress -> Try((S(state), Pressed), Str)
	press_down = |program, s0, press| {
		var $s = match press.target {
			Focused => s0
			At(loc) => {
				i = SpecRunner.need(s0.dom, loc)?
				if !SpecRunner.reachable(s0, i) {
					return Err("press target is unreachable: hidden dialog/popover or outside the topmost modal")
				}
				if (SpecRunner.focusable_in(s0.dom, i)) SpecRunner.move_focus(program, s0, i + 1) else s0
			}
		}
		key = press.key
		document = $s.browser.doc
		down_index = if ($s.focused == 0) $s.dom.root else $s.focused - 1
		activation_path = SpecRunner.pressed_path($s.dom, down_index)
		unmodelled = SpecRunner.key_unmodelled($s.dom, down_index, key)
		(down, prevented) = SpecRunner.key_phase(program, $s, "keydown", key)
		$s = down
		if !prevented and unmodelled {
			return Err("press ${key.key} has an unmodelled browser default; use fill for text input or prevent it with a keymap")
		}
		if !prevented {
			if key.key == "Escape" {
				$s = SpecRunner.dismiss_ui(program, $s)
			}
			else if key.key == "Tab" and !key.ctrl and !key.alt and !key.meta {
				$s = SpecRunner.key_tab(program, $s, key.shift)
			}
			else if key.key == "Enter" {
				n = Dom.node($s.dom, down_index)
				if (n.tag == "a" and Dom.has_attr(n, "href")) or (!key.ctrl and !key.meta and (n.tag == "button" or (n.tag == "input" and ["button", "submit", "reset"].contains(Dom.enum_attr(n, "type"))))) {
					$s = SpecRunner.key_activate(program, $s, down_index)?
				}
				else if n.tag == "input" and !key.ctrl and !key.meta and ["file", "color"].contains(Dom.enum_attr(n, "type")) {
					$s = SpecRunner.key_activate(program, $s, down_index)?
				}
				else if n.tag == "input" and !key.ctrl and !key.meta {
					match SpecRunner.ancestor($s.dom, down_index, |m| m.tag == "form") {
						Ok(form) => {
							button = Dom.find($s.dom, form, |m| (m.tag == "button" and ["", "submit"].contains(Dom.enum_attr(m, "type"))) or (m.tag == "input" and Dom.enum_attr(m, "type") == "submit"))
							$s = match button {
								Ok(i) => SpecRunner.key_activate(program, $s, i)?
								Err(_) => if (SpecRunner.implicit_inputs($s.dom, form) <= 1) SpecRunner.submit_form(program, $s, form) else $s
							}
						}
						Err(_) => {}
					}
				}
			}
		}
		Ok((SpecRunner.drain_focus(program, $s), { key, document, down_index, activation_path, prevented }))
	}

	## Key-up resolves the live focused element after navigation and native UI tasks.
	press_up : Program(state), S(state), Pressed -> Try(S(state), Str)
	press_up = |program, s0, { key, document, down_index, activation_path, prevented }| {
		var $s = s0
		up_index = if ($s.focused == 0) $s.dom.root else $s.focused - 1
		(up, up_prevented) = SpecRunner.key_phase(program, $s, "keyup", key)
		$s = up
		# Space arms only the element that received its down. A focus change
		# or disposal cannot transfer that activation to the keyup target.
		if key.key == " " and $s.browser.doc == document and !prevented and !up_prevented and up_index == down_index and $s.focused == down_index + 1 and SpecRunner.attached($s.dom, down_index) and activation_path.all(|p| Dom.node($s.dom, p.node).detach_count == p.count) {
			n = Dom.node($s.dom, up_index)
			if n.tag == "button" or (n.tag == "input" and ["button", "submit", "reset", "checkbox", "radio"].contains(Dom.enum_attr(n, "type"))) {
				$s = SpecRunner.key_activate(program, $s, up_index)?
			}
		}
		Ok($s)
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
	prevents = |dom, i, event| SpecRunner.attached(dom, i) and (Dom.target(dom, i, event, Bool.True).map_ok(|target| target.policies.bitwise_and(1) != 0 or (target.kind == 2 and event == "drop")) ?? Bool.False)

	## Only a declared paced pointermove is a report step. Capture changes
	## routing, while the located node still supplies the zone under the point.
	paced_move : S(state), Scm.PointerPlace -> Bool
	paced_move = |s, place| {
		i = SpecRunner.find(s.dom, place.target) ?? return Bool.False
		p = s.browser.pointers.get(place.id) ?? SpecRunner.idle_pointer(place.id)
		target = SpecRunner.pointer_target(s, { pointer: p, target: i })
		listener = Dom.target(s.dom, target, "pointermove", Bool.True) ?? return Bool.False
		listener.kind == 3 and listener.policies.bitwise_and(8) != 0
	}

	idle_pointer : U32 -> PointerState
	idle_pointer = |id| { id, kind: Mouse, button: Main, modifiers: 0, primary: Bool.True, down: 0, capture: 0, moved: Bool.False, suppress_mouse: Bool.False, at: Outside }

	pointer_target : S(state), { pointer : PointerState, target : U64 } -> U64
	pointer_target = |s, { pointer, target }| if (pointer.capture != 0 and SpecRunner.attached(s.dom, pointer.capture - 1)) pointer.capture - 1 else target

	## A centre inside somebody else's zone has no native geometry. Explicit
	## percentages name that zone directly; Outside needs no measured position.
	pointer_point : Dom.Model, { target : U64, at : Scm.PointerPoint } -> Try(PointerAt, Str)
	pointer_point = |dom, { target, at }| match (Dom.zone_of(dom, target), at) {
		(Err(_), Centre) => Ok(Outside)
		(Err(_), Percent(_)) => Err("give :at only for a locator in a pointer zone")
		(Ok(zone), Centre) if zone.index != target => Err("LOC lies in zone ${zone.key}; give :at in that zone with the pointer steps")
		(Ok(zone), Centre) => Ok(In({ zone: zone.key, x: 5000, y: 5000 }))
		(Ok(zone), Percent({ x, y })) => Ok(In({ zone: zone.key, x: x * 100, y: y * 100 }))
	}

	pointer_button : [Main, Middle, Secondary] -> { code : U8, held : U16 }
	pointer_button = |button| match button {
		Main => { code: 1, held: 1 }
		Middle => { code: 2, held: 4 }
		Secondary => { code: 3, held: 2 }
	}

	## Encode the pointer kind independently of Core's decoder. A cancelled
	## pointer always carries Outside, and only a press/release changes a button.
	pointer_payload : { pointer : PointerState, event : Str, at : PointerAt } -> List(U8)
	pointer_payload = |{ pointer, event, at }| {
		button = SpecRunner.pointer_button(pointer.button)
		kind : U8
		kind = match pointer.kind {
			Mouse => 0
			Pen => 1
			Touch => 2
		}
		held = if (event == "pointerup" or event == "pointercancel" or pointer.down == 0) 0.U16 else button.held
		bytes = SpecRunner.put_u32([], pointer.id).concat([kind, if (event == "pointerdown" or event == "pointerup") button.code else 0, held.bitwise_and(255).to_u8_wrap(), held.shr_zf_wrap(8).to_u8_wrap(), pointer.modifiers, if (pointer.primary) 1 else 0])
		match at {
			Outside => bytes.append(0)
			In({ zone, x, y }) => SpecRunner.put_str(bytes.concat([1, x.bitwise_and(255).to_u8_wrap(), x.shr_zf_wrap(8).to_u8_wrap(), y.bitwise_and(255).to_u8_wrap(), y.shr_zf_wrap(8).to_u8_wrap()]), zone)
		}
	}

	## Capture belongs to the declaring element, even when a row's routing id
	## is on an ancestor. A paced move shares ordinary ingress and pruning.
	fire_pointer : Program(state), S(state), { target : U64, pointer : PointerState, event : Str, at : PointerAt } -> S(state)
	fire_pointer = |program, s, { target, pointer, event, at }| {
		if !SpecRunner.attached(s.dom, target) {
			return s
		}
		listener = Dom.target(s.dom, target, event, Bool.True) ?? return s
		if listener.kind == 1 or listener.kind == 2 {
			return SpecRunner.send(program, s, listener.node, listener.handler, [])
		}
		captured = if (event == "pointerdown" and listener.policies.bitwise_and(4) != 0) { ..pointer, capture: listener.declaring + 1 } else pointer
		b = s.browser
		ready = if (event == "pointerdown") { ..s, browser: { ..b, pointers: b.pointers.insert(pointer.id, captured) } } else s
		payload = SpecRunner.pointer_payload({ pointer: captured, event, at })
		if listener.policies.bitwise_and(8) != 0 {
			SpecRunner.queue_report(program, { state: ready, source: Pointer({ element: listener.declaring, handler: listener.handler, pointer: pointer.id }), node: listener.node, handler: listener.handler, owner: Dom.lookup(s.dom, listener.node), payload })
		} else {
			SpecRunner.send(program, ready, listener.node, listener.handler, payload)
		}
	}

	## A press establishes the physical pointer before its handler runs. The
	## browser driver has one non-touch channel or at most sixteen contacts.
	pointer_down : Program(state), S(state), Scm.PointerPress -> Try(S(state), Str)
	pointer_down = |program, s, press| {
		if s.browser.pointers.contains(press.id) {
			return Err("pointer ${press.id.to_str()} is already down")
		}
		if s.browser.pointers.values().any(|p| (p.kind == Touch) != (press.kind == Touch)) {
			return Err("touch and mouse or pen gestures cannot be active together")
		}
		if press.kind != Touch and s.browser.pointers.values().any(|p| p.kind != Touch) {
			return Err("only one mouse or pen pointer may be down")
		}
		if press.kind == Touch and s.browser.pointers.values().count_if(|p| p.kind == Touch) >= 16 {
			return Err("at most 16 active touch pointers are supported by the browser driver")
		}
		if press.kind != Mouse and press.id == 1 {
			return Err("pointer id 1 is reserved for the mouse")
		}
		if press.kind == Mouse and press.id != 1 {
			return Err("the mouse pointer id is 1")
		}
		i = SpecRunner.need(s.dom, press.target)?
		at = SpecRunner.pointer_point(s.dom, { target: i, at: press.at })?
		prevented = SpecRunner.prevents(s.dom, i, "pointerdown")
		pointer = { id: press.id, kind: press.kind, button: press.button, modifiers: press.modifiers, primary: !s.browser.pointers.values().any(|p| p.kind == press.kind), down: i + 1, capture: if (press.kind == Touch) i + 1 else 0, moved: Bool.False, suppress_mouse: prevented, at }
		b = s.browser
		s1 = SpecRunner.fire_pointer(program, { ..s, browser: { ..b, pointers: b.pointers.insert(press.id, pointer), touch_multi: if (press.kind == Touch) b.pointers.values().any(|p| p.kind == Touch) or b.touch_multi else b.touch_multi } }, { target: i, pointer, event: "pointerdown", at })
		if press.kind == Touch or prevented {
			return Ok(s1)
		}
		mouse_prevented = SpecRunner.prevents(s1.dom, i, "mousedown")
		s2 = SpecRunner.fire_if(program, s1, i, "mousedown", "")
		Ok(if (mouse_prevented) s2 else SpecRunner.move_focus(program, s2, SpecRunner.focus_target(s2.dom, i)))
	}

	## Hit-test data comes from the located zone even when capture sends the
	## event to a different element. The frozen result can then be paced.
	pointer_move : Program(state), S(state), Scm.PointerPlace -> Try(S(state), Str)
	pointer_move = |program, s, place| {
		pointer = match s.browser.pointers.get(place.id) {
			Ok(p) => p
			Err(_) if place.id == 1 => SpecRunner.idle_pointer(1)
			Err(_) => return Err("pointer ${place.id.to_str()} is not down")
		}
		i = SpecRunner.need(s.dom, place.target)?
		at = SpecRunner.pointer_point(s.dom, { target: i, at: place.at })?
		if pointer.kind == Touch and at == pointer.at {
			return Err("a touch move must leave the tap slop")
		}
		next_pointer = { ..pointer, at, moved: Bool.True }
		b = s.browser
		stored = if (pointer.down == 0) s else { ..s, browser: { ..b, pointers: b.pointers.insert(pointer.id, next_pointer) } }
		target = SpecRunner.pointer_target(stored, { pointer: next_pointer, target: i })
		next = SpecRunner.fire_pointer(program, stored, { target, pointer: next_pointer, event: "pointermove", at })
		Ok(if (pointer.kind == Touch or pointer.suppress_mouse) next else SpecRunner.fire_if(program, next, target, "mousemove", ""))
	}

	## Snapshot only a pressed element's ancestor path. Counts come from MOVE,
	## REMOVE and CLEAR, so detecting a dislodged press never retains a DOM copy.
	pressed_path : Dom.Model, U64 -> List({ node : U64, parent : U64, count : U64 })
	pressed_path = |dom, i| {
		var $at = i + 1
		var $out = []
		while $at != 0 {
			n = Dom.node(dom, $at - 1)
			$out = $out.append({ node: $at - 1, parent: n.parent, count: n.detach_count })
			$at = n.parent
		}
		$out
	}

	common_ancestor : Dom.Model, { pressed : U64, released : U64 } -> U64
	common_ancestor = |dom, { pressed, released }| {
		parents = SpecRunner.pressed_path(dom, pressed).fold(Dict.empty(), |found, p| found.insert(p.node, {}))
		var $at = released + 1
		while $at != 0 {
			if parents.contains($at - 1) {
				return $at - 1
			}
			$at = Dom.node(dom, $at - 1).parent
		}
		dom.root
	}

	## A release follows any older report and uses the capture that is still
	## live, rather than a recycled route or a disposed pressed element.
	pointer_up : Program(state), S(state), Scm.PointerPlace -> Try(S(state), Str)
	pointer_up = |program, s, place| {
		pointer = s.browser.pointers.get(place.id) ? |_| "pointer ${place.id.to_str()} is not down"
		i = SpecRunner.need(s.dom, place.target)?
		at = SpecRunner.pointer_point(s.dom, { target: i, at: place.at })?
		SpecRunner.pointer_up_at(program, s, { pointer, target: i, at })
	}

	## Complete a release at an already-resolved point, including the pointer
	## sequence of a click whose initial target may since have been disposed.
	pointer_up_at : Program(state), S(state), { pointer : PointerState, target : U64, at : PointerAt } -> Try(S(state), Str)
	pointer_up_at = |program, s, { pointer, target: i, at }| {
		target = SpecRunner.pointer_target(s, { pointer, target: i })
		had_capture = pointer.capture != 0 and SpecRunner.attached(s.dom, pointer.capture - 1)
		pressed = if (had_capture) pointer.capture - 1 else pointer.down - 1
		path = SpecRunner.pressed_path(s.dom, pressed)
		dismissed = if (pointer.button == Main) SpecRunner.light_dismiss(s, pointer.down - 1, i) else s
		after_up = SpecRunner.fire_pointer(program, dismissed, { target, pointer, event: "pointerup", at })
		b = after_up.browser
		remaining = b.pointers.remove(pointer.id)
		touch_multi = b.touch_multi
		released = { ..after_up, browser: { ..b, pointers: remaining, touch_multi: if (remaining.values().any(|p| p.kind == Touch)) touch_multi else Bool.False } }
		if pointer.kind == Touch and (pointer.moved or touch_multi) {
			return Ok(released)
		}
		dislodged = path.find_first(|p| Dom.node(released.dom, p.node).detach_count != p.count)
		mouse_target = match dislodged {
			Ok(p) => if (p.parent == 0) released.dom.root else p.parent - 1
			Err(_) => target
		}
		var $next = released
		if pointer.kind == Touch and !pointer.suppress_mouse {
			$next = SpecRunner.fire_if(program, $next, mouse_target, "mousemove", "")
			mouse_prevented = SpecRunner.prevents($next.dom, mouse_target, "mousedown")
			$next = SpecRunner.fire_if(program, $next, mouse_target, "mousedown", "")
			if !mouse_prevented {
				$next = SpecRunner.move_focus(program, $next, SpecRunner.focus_target($next.dom, mouse_target))
			}
		}
		if !pointer.suppress_mouse {
			$next = SpecRunner.fire_if(program, $next, mouse_target, "mouseup", "")
		}
		if dislodged.is_ok() {
			return Ok($next)
		}
		click_target = if (had_capture) pressed else SpecRunner.common_ancestor($next.dom, { pressed: pointer.down - 1, released: i })
		event = if (pointer.button == Main) "click" else "auxclick"
		prevented = SpecRunner.prevents($next.dom, click_target, event)
		$next = SpecRunner.fire_if(program, $next, click_target, event, "")
		if (prevented or pointer.button != Main) Ok($next) else SpecRunner.default_action(program, $next, click_target)
	}

	## Light dismissal uses both actual press and release targets, never layout guesses.
	light_dismiss : S(state), U64, U64 -> S(state)
	light_dismiss = |s0, down, up| {
		var $s = s0
		for i in s0.browser.top_layer {
			if Dom.node($s.dom, i).shown == Popover and Dom.enum_attr(Dom.node($s.dom, i), "popover") == "auto" and !SpecRunner.inside($s.dom, down, i) and !SpecRunner.inside($s.dom, up, i) {
				$s = SpecRunner.change_shown($s, i, Hidden)
			}
		}
		$s
	}

	## CDP cancellation ends its whole touch set, so a named cancel is valid
	## only while that one contact remains. Nothing is synthesized for a subset.
	pointer_cancel : Program(state), S(state), U32 -> Try(S(state), Str)
	pointer_cancel = |program, s, id| {
		pointer = s.browser.pointers.get(id) ? |_| "pointer ${id.to_str()} is not down"
		if pointer.kind != Touch {
			return Err("pointer-cancel requires a touch pointer")
		}
		if s.browser.pointers.values().count_if(|p| p.kind == Touch) != 1 {
			return Err("pointer-cancel cannot cancel only the named touch while other touches are down")
		}
		target = SpecRunner.pointer_target(s, { pointer, target: pointer.down - 1 })
		next = SpecRunner.fire_pointer(program, s, { target, pointer, event: "pointercancel", at: Outside })
		b = next.browser
		Ok({ ..next, browser: { ..b, pointers: b.pointers.remove(id), touch_multi: Bool.False } })
	}

	## A click delivers Chrome's pointer and mouse sequence at the destination.
	## Preventing pointerdown suppresses compatibility mouse press/release and
	## its focus change; pointerup and click still arrive.
	## Refresh a click's pointer-kind centre contract at every actual phase:
	## earlier handlers may have installed a new zone or pointer declaration.
	click_pointer_point : Dom.Model, { located : U64, routing : U64, event : Str } -> Try(PointerAt, Str)
	click_pointer_point = |dom, { located, routing, event }| {
		if !SpecRunner.attached(dom, located) or !SpecRunner.attached(dom, routing) {
			return Ok(Outside)
		}
		listener = Dom.target(dom, routing, event, Bool.True) ?? return Ok(Outside)
		if (listener.kind == 3) SpecRunner.pointer_point(dom, { target: located, at: Centre }) else Ok(Outside)
	}

	## Deliver the complete click sequence through the same typed pointer
	## dispatch as explicit gestures, rechecking each phase against the live DOM.
	mouse_click : Program(state), S(state), U64 -> Try(S(state), Str)
	mouse_click = |program, s0, i| {
		if !s0.browser.pointers.is_empty() {
			return Err("a click cannot start while a pointer gesture is down")
		}
		at_move = SpecRunner.click_pointer_point(s0.dom, { located: i, routing: i, event: "pointermove" })?
		idle = SpecRunner.idle_pointer(1)
		s1 = SpecRunner.fire_pointer(program, s0, { target: i, pointer: idle, event: "pointermove", at: at_move })
		s2 = SpecRunner.fire_if(program, s1, i, "mousemove", "")
		at_down = SpecRunner.click_pointer_point(s2.dom, { located: i, routing: i, event: "pointerdown" })?
		press_prevented = SpecRunner.prevents(s2.dom, i, "pointerdown")
		pointer = { ..idle, down: i + 1, suppress_mouse: press_prevented, at: at_down }
		b = s2.browser
		s3 = SpecRunner.fire_pointer(program, { ..s2, browser: { ..b, pointers: b.pointers.insert(1, pointer) } }, { target: i, pointer, event: "pointerdown", at: at_down })
		s4 = if (press_prevented or !SpecRunner.attached(s3.dom, i)) s3 else {
			mouse_prevented = SpecRunner.prevents(s3.dom, i, "mousedown")
			pressed = SpecRunner.fire_if(program, s3, i, "mousedown", "")
			if (mouse_prevented) pressed else SpecRunner.move_focus(program, pressed, SpecRunner.focus_target(pressed.dom, i))
		}
		captured = s4.browser.pointers.get(1) ?? pointer
		routing = SpecRunner.pointer_target(s4, { pointer: captured, target: i })
		at_up = SpecRunner.click_pointer_point(s4.dom, { located: i, routing, event: "pointerup" })?
		SpecRunner.pointer_up_at(program, s4, { pointer: captured, target: i, at: at_up })
	}

	## The browser's default action for a click on node `i`: a checkbox
	## toggles and a radio checks (each with `input` then `change`), a submit
	## button submits its form, and a link navigates.
	default_action : Program(state), S(state), U64 -> Try(S(state), Str)
	default_action = |program, s, i| {
		if !SpecRunner.attached(s.dom, i) {
			return Ok(s)
		}
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
					url = SpecRunner.resolve(s.browser.env.url, href) ? |_| "the click navigates to ${href}, which leaves the app"
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
		entry = { url: b.env.url, doc: b.doc }
		if SpecRunner.same_document(b.env.url, url) {
			Ok(SpecRunner.popstate(program, { ..s, browser: { ..b, back: b.back.append(entry), env: { ..b.env, url }, fwd: [] } }))
		} else {
			if b.guard and b.sticky_activation {
				return Err("guarded cross-document navigation must use leave-page")
			}
			if !b.pointers.is_empty() {
				return Err("cross-document navigation while a pointer is down")
			}
			if b.reports.held {
				return Err("cross-document navigation while reports are held")
			}
			s1 = SpecRunner.mount_config(program, Scm.next_document({ ..b.env, url })?, b.settings)
			b1 = s1.browser
			Ok({ ..s1, mark: s.mark, browser: { ..b1, doc: b.doc + 1, sticky_activation: b.sticky_activation, back: b.back.append(entry), fwd: [], files: b.files, given: b.given, max_output: b.max_output } })
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
		if !SpecRunner.reachable(s, i) {
			return Err("${Scm.show_loc(loc)} is unreachable: hidden dialog/popover or outside the topmost modal")
		}
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
				s1 = { ..rest, browser: { ..rb, files: rb.files.append({ name: key, mime, bytes }), given: rb.given.append({ token: Box.unbox(handle), name: key }), network: rb.network.remove(id), report_sources: rb.report_sources.remove(id), reports: { ..rb.reports, index: rb.reports.index.remove(Request(id)) } } }
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
	## digesting bytes, and a monotonic clock for observation deadlines.
	Host : { now_ns! : () => U64, work! : List(U8), List(List(U8)), List(U8), List(List(U8)), U64 => List(U8), mint_files! : U64 => List(Box(U64)), live_files! : () => U64, sha256! : List(U8) => List(U8), live_allocations! : () => U64, live_bytes! : () => U64 }

	## Native observation yields between browser tasks and never changes app fault state.
	pump_ui! : Program(state), Host, S(state) => Try(S(state), Str)
	pump_ui! = |program, host, initial| {
		started = (host.now_ns!)()
		var $s = initial
		while !$s.browser.ui_tasks.is_empty() or $s.browser.ui_exhausted {
			if $s.browser.ui_exhausted {
				return Err("UI observation task slots exhausted")
			}
			if (host.now_ns!)() - started >= 20000000000 {
				return Err("UI observation did not reach idle within 20 seconds")
			}
			# A browser task starts a fresh ingress turn budget.
			$s = SpecRunner.drain_focus(program, SpecRunner.deliver_ui(program, { ..$s, draining: False, turns: 0 }))
		}
		Ok($s)
	}

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
		$s = SpecRunner.pump_ui!(program, host, $s).map_err(|message| { step: 0, at: spec.steps.first() ?? crash "a parsed spec has steps", message })?
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
		if $s.browser.reports.held {
			return Err({ step: spec.steps.len() - 1, at: spec.steps.last() ?? crash "a parsed spec has steps", message: "spec ended while reports were held" })
		}
		Ok($s)
	}

	## Take one step as the `spec` command takes it: the steps its host
	## serves (a worker job run in a child process, a fetched body or a
	## file given through handles it mints, a digest it computes, the live
	## handle count) through `host`, every other step through `one`.
	step! : Program(state), Host, S(state), Scm.Op => Try(S(state), Str)
	step! = |program, host, initial, op| {
		s = if (SpecRunner.is_occurrence(initial, op)) SpecRunner.release_reports(program, initial) else initial
		result = match op {
			Press(press) => {
				activated = SpecRunner.activate_step(s, op)
				(down, context) = SpecRunner.press_down(program, activated, press)?
				ready = SpecRunner.pump_ui!(program, host, down)?
				SpecRunner.press_up(program, ready, context)
			}
			Dismiss => {
				(down, context) = SpecRunner.press_down(program, s, { target: Focused, key: { key: "Escape", code: "Escape", ctrl: False, alt: False, shift: False, meta: False } })?
				ready = SpecRunner.pump_ui!(program, host, down)?
				SpecRunner.press_up(program, ready, context)
			}
			_ => match (SpecRunner.file_count(s.dom, op), op) {
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
		}
		SpecRunner.pump_ui!(program, host, result?)
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
					if listener.kind != 3 {
						$out = $out.append((i, listener.event))
					}
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

	## A walk cannot accept a leave dialog. Skip click targets inside anchors
	## while a guard is on; that click could itself grant sticky activation.
	walk_candidates : S(state) -> List((U64, Str))
	walk_candidates = |state| SpecRunner.candidates(state.dom).keep_if(|(index, event)| !(state.browser.guard and event == "click" and SpecRunner.ancestor(state.dom, index, |entry| entry.tag == "a" and Dom.has_attr(entry, "href")).is_ok()))

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

	## Walks enumerate only the live tree, as they enumerate controls. A grip
	## owns its zone, so its centre has the same meaning in both runners.
	pointer_places : Dom.Model, [Grips, Zones] -> List({ target : Scm.Loc, index : U64 })
	pointer_places = |dom, what| {
		var $stack = [dom.root]
		var $out = []
		while !$stack.is_empty() {
			i = $stack.last() ?? crash "SpecRunner.pointer_places: stack has a node"
			$stack = $stack.drop_last(1)
			n = Dom.node(dom, i)
			has_zone = !Dom.live_value(n, "pointer_zone").is_empty()
			is_grip = n.hs.any(|h| h.kind == 3 and h.event == "pointerdown")
			if has_zone and !SpecRunner.disabled(n) and (what == Zones or is_grip) {
				id = Dom.attr_of(n, "data-testid")
				label = Dom.attr_of(n, "aria-label")
				if !id.is_empty() {
					$out = $out.append({ target: TestId(id), index: i })
				} else if !label.is_empty() {
					$out = $out.append({ target: Label(label), index: i })
				}
			}
			$stack = $stack.concat(n.kids)
		}
		$out
	}

	## A gesture is made from the ordinary pointer steps, with settling checked
	## at every boundary rather than only at the final release or cancel.
	walk_pointer : Program(state), S(state), { target : Scm.Loc, choice : U64 } -> Try(S(state), Str)
	walk_pointer = |program, s, { target, choice }| {
		kind = if (choice % 4 == 3) Touch else Mouse
		id = if (kind == Mouse) 1.U32 else 2.U32
		var $s = SpecRunner.one(program, s, PointerDown({ target, at: Centre, id, kind, button: Main, modifiers: 0 }))?
		SpecRunner.check_settled(program, $s)?
		$s = SpecRunner.one(program, $s, HoldReports)?
		var $last = { target, at: Centre, id }
		var $count = 0.U64
		while $count < 2 + choice % 2 {
			places = SpecRunner.pointer_places($s.dom, Zones)
			if places.is_empty() {
				break
			}
			place = places.get((choice + $count) % places.len()) ?? crash "SpecRunner.walk_pointer: place index is bounded"
			$last = { target: place.target, at: Percent({ x: if ($count % 2 == 0) 25 else 75, y: 50 }), id }
			$s = SpecRunner.one(program, $s, PointerMove($last))?
			SpecRunner.check_settled(program, $s)?
			$count = $count + 1
		}
		$s = SpecRunner.one(program, $s, ReleaseReports)?
		SpecRunner.check_settled(program, $s)?
		if kind == Touch and choice % 8 == 3 {
			$s = SpecRunner.one(program, $s, PointerCancel(id))?
		} else if SpecRunner.find($s.dom, $last.target).is_ok() {
			$s = SpecRunner.one(program, $s, PointerUp($last))?
		} else {
			pointer = $s.browser.pointers.get(id) ? |_| "a walk's active pointer disappeared"
			$s = SpecRunner.pointer_up_at(program, $s, { pointer, target: $s.dom.root, at: Outside })?
		}
		SpecRunner.check_settled(program, $s)?
		Ok($s)
	}

	## The fault classes a walk loses a worker job to, in the order a byte
	## picks them.
	faults : List(Scm.WorkFault)
	faults = [Contract, ResourceLimit, OutOfMemory, AppCrash, ExpectFailed, Unavailable, Executor]

	## What the browser around the app can do next, besides the user: answer
	## a pending request, tick a live interval, change visibility or
	## connectivity for a live subscription, or deliver a message the specs
	## emit on a port with a live subscription.
	Service : [Answer(Pending), Tick(U32), ToggleVisibility, ToggleOnline, Emit(Str), BurstOnline, BurstVisibility, BurstPort(Str), PointerGesture(Scm.Loc), LayoutReport({ target : Scm.Loc, kind : U8 }), ToggleMedia(Str), MoveClock]

	## Walks enumerate named live observations as they enumerate controls and
	## pointer zones. Their injected facts need no browser geometry.
	layout_reports : Dom.Model -> List(Service)
	layout_reports = |dom| {
		var $stack = [dom.root]
		var $out = []
		while !$stack.is_empty() {
			i = $stack.last() ?? crash "SpecRunner.layout_reports: nonempty stack"
			$stack = $stack.drop_last(1)
			n = Dom.node(dom, i)
			test_id = Dom.attr_of(n, "data-testid")
			label = Dom.attr_of(n, "aria-label")
			if !test_id.is_empty() or !label.is_empty() {
				target = if (!test_id.is_empty()) TestId(test_id) else Label(label)
				for listener in n.hs {
					if listener.kind >= 6 and listener.kind <= 8 {
						$out = $out.append(LayoutReport({ target, kind: listener.kind }))
					}
				}
			}
			$stack = $stack.concat(n.kids)
		}
		$out
	}

	## Every service the browser can do now, in a fixed order.
	services : Book, S(state) -> List(Service)
	services = |bk, s| {
		b = s.browser
		var $out = [MoveClock].concat(b.pending.map(|p| Answer(p))).concat(SpecRunner.pointer_places(s.dom, Grips).map(|p| PointerGesture(p.target))).concat(SpecRunner.layout_reports(s.dom))
		var $ticks = []
		var $ports = []
		var $vis = Bool.False
		var $online = Bool.False
		var $media = []
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
				MediaSub(query) if !$media.contains(query) => {
					$media = $media.append(query)
				}
				PortSub(port, _) if !$ports.contains(port) and bk.messages.any(|m| m.port == port) => {
					$ports = $ports.append(port)
				}
				_ => {}
			}
		}
		$out = $out.concat($ticks.map(|ms| Tick(ms))).concat($ports.map(|p| Emit(p))).concat($media.map(|query| ToggleMedia(query)))
		$out = $out.concat($ports.keep_if(|port| b.latest_ports.contains(port)).map(|port| BurstPort(port)))
		$out = if ($vis) $out.append(ToggleVisibility).append(BurstVisibility) else $out
		if ($online) $out.append(ToggleOnline).append(BurstOnline) else $out
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
			LayoutReport({ target, kind }) => {
				op = match kind {
					6 => Scroll({ target, top: ((v % 20) * 20).to_u32_wrap(), left: 0 })
					7 => ReportSize({ target, width: (160 * (1 + v % 4)).to_u32_wrap(), height: (80 * (1 + v % 6)).to_u32_wrap() })
					8 => ReportSeen({ target, intersecting: v % 2 == 0, ratio_permille: if (v % 2 == 0) 500 else 0 })
					_ => crash "SpecRunner.serve!: layout service kind"
				}
				Ok((SpecRunner.one(program, s, op)?, { what: Scm.op_name(op), kind: Service }))
			}
			ToggleMedia(query) => {
				prior = b.env.media.find_first(|(name, _)| name == query) ? |_| "a live media subscription has no declared query"
				Ok((SpecRunner.one(program, s, SetMedia({ query, matches: !prior.1 }))?, { what: "set-media ${query}", kind: Service }))
			}
			PointerGesture(target) => Ok((SpecRunner.walk_pointer(program, s, { target, choice: v })?, { what: "pointer gesture", kind: UserEvent }))
			BurstOnline | BurstVisibility | BurstPort(_) => {
				var $s = SpecRunner.one(program, s, HoldReports)?
				var $count = 0.U64
				while $count < 2 + v % 2 {
					current = $s.browser
					op = match service {
						BurstOnline => SetOnline(if (current.env.online) Offline else Online)
						BurstVisibility => SetVisibility(if (current.env.visible) Hidden else Visible)
						BurstPort(port) => {
							messages = bk.messages.keep_if(|m| m.port == port)
							json = (messages.get((v + $count) % messages.len().max(1)) ?? { port, json: "null" }).json
							EmitPort({ port, json })
						}
						_ => crash "SpecRunner.serve!: a burst service"
					}
					$s = SpecRunner.one(program, $s, op)?
					$count = $count + 1
				}
				Ok((SpecRunner.one(program, $s, ReleaseReports)?, { what: "report burst", kind: Service }))
			}
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
			Tick(ms) => {
				advanced = SpecRunner.one(program, s, AdvanceTime(ms.to_u64()))?
				Ok((SpecRunner.one(program, advanced, TickInterval(ms.to_u64()))?, { what: "advance-time and tick-interval ${ms.to_str()}", kind: Service }))
			}
			MoveClock => {
				duration = 1000 + v % 86399001
				op = if v % 8 == 0 {
					back = b.env.now_ms.to_i128() - duration.to_i128()
					if back < -9223372036854775808 {
						return Err("walk clock moved below I64 range")
					}
					SetTime(back.to_i64_wrap())
				} else AdvanceTime(duration)
				Ok((SpecRunner.one(program, s, op)?, { what: Scm.op_name(op), kind: Service }))
			}
			ToggleVisibility => Ok((SpecRunner.one(program, s, SetVisibility(if (b.env.visible) Hidden else Visible))?, { what: "set-visibility", kind: Service }))
			ToggleOnline => Ok((SpecRunner.one(program, s, SetOnline(if (b.env.online) Offline else Online))?, { what: "set-online", kind: Service }))
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
		cs = SpecRunner.walk_candidates(s)
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
						host = { now_ns!: io.now_ns!, work!: io.work!, mint_files!: io.mint_files!, live_files!: io.live_files!, sha256!: io.sha256!, live_allocations!: io.live_allocations!, live_bytes!: io.live_bytes! }
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
		host = { now_ns!: io.now_ns!, work!: io.work!, mint_files!: io.mint_files!, live_files!: io.live_files!, sha256!: io.sha256!, live_allocations!: io.live_allocations!, live_bytes!: io.live_bytes! }
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
## each boot section is tagged and length-bounded in ascending order.
expect SpecRunner.encode_boot({ url: "/a", storage: [("k", "v")], online: Bool.False }) == [1, 6, 0, 0, 0, 2, 0, 0, 0, '/', 'a', 2, 15, 0, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 'k', 1, 0, 0, 0, 'v', 3, 1, 0, 0, 0, 0, 4, 1, 0, 0, 0, 1, 6, 0, 0, 0, 0, 7, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 13, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 101, 110, 45, 85, 83, 10, 39, 0, 0, 0, 3, 0, 0, 0, 85, 84, 67, 0, 0, 0, 0, 0, 0, 0, 128, 255, 255, 255, 255, 255, 255, 255, 127, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 11, 5, 0, 0, 0, 1, 0, 0, 0, 0]

## An HTTP result carries status, headers and the body as the rest.
expect SpecRunner.encode_http(422, [{ name: "a", value: "b" }], "x") == [1, 0xA6, 0x01, 1, 0, 0, 0, 1, 0, 0, 0, 'a', 1, 0, 0, 0, 'b', 'x']

## Rejections are a timeout or a network failure carrying the detail.
expect SpecRunner.encode_reject(Timeout, "") == [7] and SpecRunner.encode_reject(Network, "offline") == [2, 'o', 'f', 'f', 'l', 'i', 'n', 'e']

## Declared storage keys decode from `count:u32 (key:str)*`.
expect SpecRunner.decode_keys([2, 15, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 'a', 2, 0, 0, 0, 'b', 'c', 5, 4, 0, 0, 0, 0, 0, 0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 0, 10, 2, 0, 0, 0, 110, 1, 11, 4, 0, 0, 0, 0, 0, 0, 0]) == ["a", "bc"]

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
			cmds = if (next == 4096) [] else SpecRunner.put_u32([0, 18, 1], if (node == 1) 2 else 1)
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
	done = SpecRunner.drain_focus(program, { ..s, dom, draining: Bool.True, after_batch: [Ref({ action: Focus(1), node: 1, target: Dom.lookup(dom, 1) })] })
	{ count: done.inst, turns: done.turns, queued: done.after_batch.len(), focused: done.focused } == { count: 4096, turns: 4096, queued: 0, focused: b + 1 }
}

## Both focus effects in one batch land before either handler runs. A focus
## command from the first handler joins behind the second's queued event.
expect {
	program : SpecRunner.Program(List(U32))
	program = {
		version: Dom.protocol_version,
		keys: || [],
		init: |_| ([], [], []),
		event: |seen, _buf, _work, node, _handler, _payload| (seen.append(node), if (node == 1) SpecRunner.put_u32([0, 18, 1], 3) else [], List.repeat(0, 8)),
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
	done = SpecRunner.drain_focus(program, { ..s, dom: $dom, after_batch: [Ref({ action: Focus(1), node: 1, target: Dom.lookup($dom, 1) }), Ref({ action: Focus(1), node: 2, target: Dom.lookup($dom, 2) })] })
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
		event: |count, _buf, _work, node, _handler, _payload| (count + 1, SpecRunner.put_u32([0, 18, 1], if (node == 1) 2 else 1), List.repeat(0, 8)),
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
	stopped = SpecRunner.drain_focus(program, { ..s, dom: $dom, after_batch: [Ref({ action: Focus(1), node: 1, target: Dom.lookup($dom, 1) })] })
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
			(seen.append(id), [0].concat(cmds), List.repeat(0, 8))
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
	done = SpecRunner.drain_focus(program, { ..s, dom, after_batch: [Ref({ action: Focus(1), node: 1, target: Dom.lookup(dom, 1) }), Ref({ action: Focus(1), node: 2, target: Dom.lookup(dom, 2) })] })
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
	focused = SpecRunner.drain_focus(program, { ..s, dom: $dom, after_batch: [1.U32, 2, 3, 5].map(|id| Ref({ action: Focus(1), node: id, target: Dom.lookup($dom, id) })) })
	cmds = SpecRunner.put_u32([18, 1], 1).concat(SpecRunner.put_u32([5], 1))
	removed = SpecRunner.drain_focus(program, SpecRunner.take_batch(focused, 0, [0].concat(cmds)))
	{ kept: focused.focused, removed: removed.focused, calls: removed.inst, waiting: removed.after_batch.len() } == { kept: Dom.lookup(focused.dom, 1) + 1, removed: 0, calls: 0, waiting: 0 }
}

## A declaration's kind and policy bits survive the wire independently of
## its event name. Property commands retain their live values and mirrors.
expect {
	element = SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([8], 1), 0), 0), "input")
	listener = SpecRunner.put_u32(SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32([11], 1), 7), "change").append(2), 2)
	value = SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(1), "first")
	checked = SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(2), "true")
	decoded = Dom.apply_full(Dom.new({}), [0].concat(element).concat(listener).concat(value).concat(checked))
	i = Dom.lookup(decoded.dom, 1)
	target = Dom.target(decoded.dom, i, "change", Bool.True)?
	n = Dom.node(decoded.dom, i)
	{ target, value: Dom.live_value(n, "value"), checked: Dom.live_value(n, "checked"), mirror: Dom.attr_of(n, "value"), values: decoded.values, writes: decoded.written } == {
		target: { node: 1, handler: 7, event: "change", kind: 2, policies: 2, declaring: i },
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
	decoded = Dom.apply_full(Dom.new({}), [0].concat(define).concat(instance).concat(update))
	i = Dom.lookup(decoded.dom, 1)
	{ checked: Dom.live_value(Dom.node(decoded.dom, i), "checked"), target: Dom.target(decoded.dom, i, "change", Bool.True)?, writes: decoded.written, ops: decoded.ops } == {
		checked: "true",
		target: { node: 1, handler: 0, event: "change", kind: 1, policies: 1, declaring: i },
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
	decoded = Dom.apply(dom, [0].concat(attribute))
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
	present = Dom.apply(Dom.new({}), [0].concat(element).concat(empty_alt).concat(ordinary_checked))
	i = Dom.lookup(present, 1)
	removed = Dom.apply(present, [0].concat(removed_alt))
	static_attrs = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_str([1], "img").append(1), "alt"), "")
	template = SpecRunner.put_str(static_attrs.concat([0, 1, 2, 0]), "aria-label")
	define = SpecRunner.put_u32(SpecRunner.put_u32([7], 0), template.len().to_u32_wrap()).concat(template)
	instance = SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([1], 2), 0), 0), 0).append(1), "")
	row_present = Dom.apply(removed, [0].concat(define).concat(instance))
	row = Dom.lookup(row_present, 2)
	row_absent = Dom.apply(row_present, SpecRunner.put_u32([0, 3], 2).concat([0, 0]))
	row_restored = Dom.apply(row_absent, SpecRunner.put_str(SpecRunner.put_u32([0, 3], 2).concat([0, 1]), ""))
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

## A protocol probe records delivered inputs without reactive semantics;
## the ingress tests can distinguish frozen payloads and exact turn order.
report_probe : {} -> SpecRunner.Program(List({ id : U32, payload : List(U8) }))
report_probe = |_| {
	version: Dom.protocol_version,
	keys: || [2, 4, 0, 0, 0, 0, 0, 0, 0, 5, 4, 0, 0, 0, 0, 0, 0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 0, 10, 2, 0, 0, 0, 110, 1, 11, 4, 0, 0, 0, 0, 0, 0, 0],
	init: |_| ([], [0, 13, 1, 0, 0, 0, 6, 13, 2, 0, 0, 0, 7], List.repeat(0, 8)),
	event: |seen, _buf, _work, _node, id, payload| (seen.append({ id, payload }), [], List.repeat(0, 8)),
	files: |seen, _buf, _work, _node, _handler, _payload, _files| (seen, [], List.repeat(0, 8)),
	settled: |_| Ok({}),
	live: |_| [],
}

## A source keeps its first queue position while replacement freezes its
## newest payload; assertions inside the held frame observe no turn.
expect {
	program = report_probe({})
	s = SpecRunner.mount_in(program, {})
	a = SpecRunner.one(program, s, HoldReports)?
	b = SpecRunner.one(program, a, SetOnline(Offline))?
	c = SpecRunner.one(program, b, SetVisibility(Hidden))?
	d = SpecRunner.one(program, c, SetOnline(Online))?
	_ = SpecRunner.one(program, d, ExpectReportsReplaced(1))?
	before = d.inst
	after = SpecRunner.one(program, d, ReleaseReports)?
	{ before, delivered: after.inst, indexed: after.browser.reports.index.len() } == {
		before: [],
		delivered: [{ id: 1, payload: [8, 1] }, { id: 2, payload: [9, 0] }],
		indexed: 0,
	}
}

## An occurrence pins reports in constant work by advancing the epoch;
## later reports begin behind it and cannot overwrite the earlier payload.
expect {
	program = report_probe({})
	s = SpecRunner.mount_in(program, {})
	a = SpecRunner.report(program, { state: s, id: 1, payload: [8, 0] })
	b = SpecRunner.send(program, { ..a, applying_focus: Bool.True }, SpecRunner.fx_node, 9, [5])
	c = SpecRunner.report(program, { state: b, id: 1, payload: [8, 1] })
	d = SpecRunner.report(program, { state: c, id: 1, payload: [8, 0] })
	after = SpecRunner.release_reports(program, { ..d, applying_focus: Bool.False })
	{ seen: after.inst, replacements: after.browser.reports.replaced, indexed: after.browser.reports.index.len() } == {
		seen: [{ id: 1, payload: [8, 0] }, { id: 9, payload: [5] }, { id: 1, payload: [8, 0] }],
		replacements: 1,
		indexed: 0,
	}
}

## Cancelling a source discards both pinned and replaceable reports; a
## later report from the cancelled source neither queues nor counts.
expect {
	program = report_probe({})
	s = SpecRunner.mount_in(program, {})
	a = SpecRunner.report(program, { state: s, id: 1, payload: [8, 0] })
	b = SpecRunner.send(program, { ..a, applying_focus: Bool.True }, SpecRunner.fx_node, 9, [5])
	c = SpecRunner.report(program, { state: b, id: 1, payload: [8, 1] })
	cancelled = { ..c, applying_focus: Bool.False, browser: SpecRunner.absorb(c.browser, [Cancel(1)]) }
	after = SpecRunner.release_reports(program, SpecRunner.report(program, { state: cancelled, id: 1, payload: [8, 0] }))
	{ seen: after.inst, replacements: after.browser.reports.replaced, indexed: after.browser.reports.index.len(), live_sources: after.browser.report_sources.len() } == {
		seen: [{ id: 9, payload: [5] }],
		replacements: 0,
		indexed: 0,
		live_sources: 1,
	}
}

## A hold belongs to one document: nested holds, unmatched releases and a
## new document during a hold fail before they can change that contract.
expect {
	program = report_probe({})
	s = SpecRunner.mount_in(program, {})
	held = SpecRunner.one(program, s, HoldReports)?
	{ nested: SpecRunner.one(program, held, HoldReports).map_ok(|_| {}), unmatched: SpecRunner.one(program, s, ReleaseReports).map_ok(|_| {}), navigation: SpecRunner.one(program, held, Navigate("/next")).map_ok(|_| {}) } == {
		nested: Err("hold-reports while reports are already held"),
		unmatched: Err("release-reports while reports are not held"),
		navigation: Err("cross-document navigation while reports are held"),
	}
}

## At the idle ingress bound, an occurrence pins the waiting reports before
## the oldest runs, and all 4096 remaining entries fit and deliver normally.
expect {
	program = report_probe({})
	initial = SpecRunner.mount_in(program, {})
	var $sources = initial.browser.report_sources
	var $id = 1.U32
	while $id <= 4096 {
		$sources = $sources.insert($id, {})
		$id = $id + 1
	}
	var $s = { ..initial, browser: { ..initial.browser, report_sources: $sources } }
	$id = 1
	while $id <= 4096 {
		$s = SpecRunner.report(program, { state: $s, id: $id, payload: [8, 0] })
		$id = $id + 1
	}
	after = SpecRunner.send(program, $s, SpecRunner.fx_node, 9000, [5])
	{ fault: after.fault, delivered: after.inst.len(), last: after.inst.last()?, queued: after.event_queue.len(), indexed: after.browser.reports.index.len() } == {
		fault: Healthy,
		delivered: 4097,
		last: { id: 9000, payload: [5] },
		queued: 0,
		indexed: 0,
	}
}

## Storage is read when its later task runs, after preceding ingress and
## batch focus effects: a queued occurrence's write must precede the read.
expect {
	base = report_probe({})
	program = {
		..base,
		event: |seen, _buf, _work, _node, id, payload| {
			commands = match id {
				1 => SpecRunner.put_str([13, 3, 0, 0, 0, 2], "k")
				9 => SpecRunner.put_str(SpecRunner.put_str([16, 1], "k"), "new")
				_ => []
			}
			(seen.append({ id, payload }), [0].concat(commands), List.repeat(0, 8))
		},
	}
	initial = SpecRunner.mount_in(program, { storage: [("k", "old")] })
	queued = SpecRunner.report(program, { state: initial, id: 1, payload: [8, 0] })
	after = SpecRunner.send(program, queued, SpecRunner.fx_node, 9, [])
	{ delivered: after.inst, pending_reads: after.browser.gets } == {
		delivered: [{ id: 1, payload: [8, 0] }, { id: 9, payload: [] }, { id: 3, payload: [3, 'n', 'e', 'w'] }],
		pending_reads: [],
	}
}

## A protocol recorder isolates browser input ordering from application logic.
## Pointer payload validation remains the real engine's separate contract.
pointer_probe : {} -> SpecRunner.Program(List({ handler : U32, payload : List(U8) }))
pointer_probe = |_props| {
	version: Dom.protocol_version,
	keys: || [2, 4, 0, 0, 0, 0, 0, 0, 0, 5, 4, 0, 0, 0, 0, 0, 0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 0, 10, 2, 0, 0, 0, 110, 1, 11, 4, 0, 0, 0, 0, 0, 0, 0],
	init: |_| ([], [], List.repeat(0, 8)),
	event: |seen, _buf, _work, _node, handler, payload| (seen.append({ handler, payload }), [], List.repeat(0, 8)),
	files: |seen, _buf, _work, _node, _handler, _payload, _files| (seen, [], List.repeat(0, 8)),
	settled: |_| Ok({}),
	live: |_| [],
}

## Neither an old capturing element nor its recycled routing id receives a
## later release. The actual live target's ancestor handles it, with no stale
## click or default navigation from the detached anchor.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, old) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "a", rn: 1, attrs: [("data-testid", "old"), ("href", "/phantom")], props: [("pointer_zone", "old")], hs: [{ event: "pointerdown", handler: 1, kind: 3, policies: 4 }, { event: "pointerup", handler: 2, kind: 3, policies: 0 }, { event: "click", handler: 3, kind: 1, policies: 0 }] })
	(d2, outside) = Dom.add_node(d1, { ..Dom.empty_node, tag: "div", rn: 2, attrs: [("data-testid", "outside")], hs: [{ event: "pointerup", handler: 4, kind: 3, policies: 0 }] })
	dom = Dom.bind(Dom.bind(Dom.insert(Dom.insert(d2, d2.root, old, Err(End)), d2.root, outside, Err(End)), 1, old), 2, outside)
	down = SpecRunner.one(program, { ..base, dom }, PointerDown({ target: TestId("old"), at: Centre, id: 1, kind: Mouse, button: Main, modifiers: 0 }))?
	detached = Dom.detach(Dom.forget_subtree(down.dom, old), old)
	(d3, replacement) = Dom.add_node(detached, { ..Dom.empty_node, tag: "a", rn: 1, attrs: [("href", "/replacement")], hs: [{ event: "pointerup", handler: 5, kind: 3, policies: 0 }, { event: "click", handler: 6, kind: 1, policies: 0 }] })
	up = SpecRunner.one(program, { ..down, dom: Dom.bind(Dom.insert(d3, d3.root, replacement, Err(End)), 1, replacement) }, PointerUp({ target: TestId("outside"), at: Centre, id: 1 }))?
	{ handlers: up.inst.map(|event| event.handler), url: up.browser.env.url, active: up.browser.pointers.len() } == { handlers: [1, 4], url: "/", active: 0 }
}

## A multi-contact touch set never synthesizes a tap's mouse events, even
## after its nonprimary contact ends. A later single tap starts fresh.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, zone) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "div", rn: 1, attrs: [("data-testid", "zone")], props: [("pointer_zone", "zone")], hs: [{ event: "pointerdown", handler: 1, kind: 3, policies: 4 }, { event: "pointerup", handler: 2, kind: 3, policies: 0 }, { event: "mousemove", handler: 4, kind: 1, policies: 0 }, { event: "mousedown", handler: 5, kind: 1, policies: 0 }, { event: "mouseup", handler: 6, kind: 1, policies: 0 }, { event: "click", handler: 7, kind: 1, policies: 0 }] })
	s = { ..base, dom: Dom.bind(Dom.insert(d1, d1.root, zone, Err(End)), 1, zone) }
	press = { target: TestId("zone"), at: Centre, id: 2, kind: Touch, button: Main, modifiers: 0 }
	a = SpecRunner.one(program, s, PointerDown(press))?
	b = SpecRunner.one(program, a, PointerDown({ ..press, id: 3 }))?
	c = SpecRunner.one(program, b, PointerUp({ target: TestId("zone"), at: Centre, id: 3 }))?
	d = SpecRunner.one(program, c, PointerUp({ target: TestId("zone"), at: Centre, id: 2 }))?
	e = SpecRunner.one(program, d, PointerDown(press))?
	f = SpecRunner.one(program, e, PointerUp({ target: TestId("zone"), at: Centre, id: 2 }))?
	f.inst.map(|event| event.handler) == [1, 1, 2, 2, 1, 2, 4, 5, 6, 7]
}

## A mousedown can install the first typed pointer handler. The centre rule
## is checked again for pointerup instead of trusting the initial click tree.
expect {
	probe = pointer_probe({})
	zone = SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(3), "dynamic")
	listener = SpecRunner.put_u32(SpecRunner.put_u32([11], 1), 8)
	commands = zone.concat(SpecRunner.put_str(listener, "pointerup").concat([3, 0, 0, 0, 0]))
	program = { ..probe, event: |seen, _buf, _work, _node, handler, payload| (seen.append({ handler, payload }), if (handler == 9) [0].concat(commands) else [], List.repeat(0, 8)) }
	base = SpecRunner.mount_in(program, {})
	(d1, parent) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "div", rn: 1 })
	(d2, child) = Dom.add_node(d1, { ..Dom.empty_node, tag: "button", rn: 2, hs: [{ event: "mousedown", handler: 9, kind: 1, policies: 0 }] })
	dom = Dom.bind(Dom.bind(Dom.insert(Dom.insert(d2, d2.root, parent, Err(End)), parent, child, Err(End)), 1, parent), 2, child)
	SpecRunner.mouse_click(program, { ..base, dom }, child) == Err("LOC lies in zone dynamic; give :at in that zone with the pointer steps")
}

## A zone installed on LOC itself has a defined centre. The later typed
## pointerup reads that zone after mousedown's command batch has applied.
expect {
	probe = pointer_probe({})
	zone = SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(3), "dynamic")
	listener = SpecRunner.put_u32(SpecRunner.put_u32([11], 1), 8)
	commands = zone.concat(SpecRunner.put_str(listener, "pointerup").concat([3, 0, 0, 0, 0]))
	program = { ..probe, event: |seen, _buf, _work, _node, handler, payload| (seen.append({ handler, payload }), if (handler == 9) [0].concat(commands) else [], List.repeat(0, 8)) }
	base = SpecRunner.mount_in(program, {})
	(d1, button) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "button", rn: 1, hs: [{ event: "mousedown", handler: 9, kind: 1, policies: 0 }] })
	dom = Dom.bind(Dom.insert(d1, d1.root, button, Err(End)), 1, button)
	after = SpecRunner.mouse_click(program, { ..base, dom }, button)?
	after.inst == [
		{ handler: 9, payload: [] },
		{ handler: 8, payload: [1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 136, 19, 136, 19, 7, 0, 0, 0, 'd', 'y', 'n', 'a', 'm', 'i', 'c'] },
	]
}

## ApplyValue lands the rendered value when a user's draft differs but the
## value hole emitted nothing; applying to another node keeps focused state.
expect {
	probe = pointer_probe({})
	base = SpecRunner.fresh([], SpecRunner.fresh_browser({}))
	(d1, input) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "input", rn: 1, attrs: [("value", "rendered")], props: [("value", "draft")] })
	dom = Dom.bind(Dom.insert(d1, d1.root, input, Err(End)), 1, input)
	state = { ..base, dom, focused: input + 1, after_batch: [Ref({ node: 1, action: Focus(4), target: Dom.lookup(dom, 1) })] }
	after = SpecRunner.drain_focus(probe, state)
	{ shown: Dom.live_value(Dom.node(after.dom, input), "value"), focus: after.focused, held: after.deferred } == { shown: "rendered", focus: input + 1, held: NoValue }
}

## Space does not transfer an armed activation when its keydown focuses
## another button, including when the original button is removed first.
expect {
	focus = SpecRunner.put_u32([18, 1], 2)
	commands = [focus, SpecRunner.put_u32([5], 1).concat(focus)]
	commands.map(
		|batch| {
			probe = pointer_probe({})
			program = { ..probe, event: |seen, _buf, _work, _node, handler, payload| (seen.append({ handler, payload }), if (handler == 9) [0].concat(batch) else [], List.repeat(0, 8)) }
			base = SpecRunner.mount_in(program, {})
			(d1, a) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "button", rn: 1, attrs: [("type", "button")], keymaps: Dict.empty().insert("keydown", Dom.parse_keymap("a*")), hs: [{ event: "keydown", handler: 9, kind: 4, policies: 0 }, { event: "click", handler: 6, kind: 1, policies: 0 }] })
			(d2, b) = Dom.add_node(d1, { ..Dom.empty_node, tag: "button", rn: 2, attrs: [("type", "button")], keymaps: Dict.empty().insert("keyup", Dom.parse_keymap("a*")), hs: [{ event: "keyup", handler: 8, kind: 4, policies: 0 }, { event: "click", handler: 7, kind: 1, policies: 0 }] })
			dom = Dom.bind(Dom.bind(Dom.insert(Dom.insert(d2, d2.root, a, Err(End)), d2.root, b, Err(End)), 1, a), 2, b)
			after = SpecRunner.press_key(program, { ..base, dom, focused: a + 1 }, { target: Focused, key: { key: " ", code: "Space", ctrl: False, alt: False, shift: False, meta: False } })?
			Ok(after.inst.map(|event| event.handler))
		},
	) == [Ok([9, 8]), Ok([9, 8])]
}

## Control and Meta suppress Enter activation on a button; Alt and Shift
## preserve it. Space remains an activation for each modifier on keyup.
expect {
	probe = pointer_probe({})
	base = SpecRunner.mount_in(probe, {})
	(d1, button) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "button", rn: 1, attrs: [("type", "button")], hs: [{ event: "click", handler: 7, kind: 1, policies: 0 }] })
	dom = Dom.bind(Dom.insert(d1, d1.root, button, Err(End)), 1, button)
	state = { ..base, dom, focused: button + 1 }
	keys = [
		{ key: "Enter", code: "Enter", ctrl: True, alt: False, shift: False, meta: False },
		{ key: "Enter", code: "Enter", ctrl: False, alt: False, shift: False, meta: True },
		{ key: "Enter", code: "Enter", ctrl: False, alt: True, shift: False, meta: False },
		{ key: "Enter", code: "Enter", ctrl: False, alt: False, shift: True, meta: False },
	]
	enter = keys.map(|key| SpecRunner.press_key(probe, state, { target: Focused, key }).map_ok(|s| s.inst.map(|event| event.handler)))
	space = keys.map(|key| SpecRunner.press_key(probe, state, { target: Focused, key: { ..key, key: " ", code: "Space" } }).map_ok(|s| s.inst.map(|event| event.handler)))
	{ enter, space } == { enter: [Ok([]), Ok([]), Ok([7]), Ok([7])], space: [Ok([7]), Ok([7]), Ok([7]), Ok([7])] }
}

## Modified link Enter is refused from the shared parser data because its
## current-document, new-context or download default depends on the system.
expect {
	(d1, link) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "a", attrs: [("href", "#next")] })
	plain = { key: "Enter", code: "Enter", ctrl: False, alt: False, shift: False, meta: False }
	[plain, { ..plain, ctrl: True }, { ..plain, alt: True }, { ..plain, shift: True }, { ..plain, meta: True }].map(|key| SpecRunner.key_unmodelled(d1, link, key)) == [Bool.False, Bool.True, Bool.True, Bool.True, Bool.True]
}

## Enter on checkbox, radio and range can submit a form. File and color
## instead activate their own input, without an implicit submit.
expect {
	["checkbox", "radio", "range", "file", "color"].map(
		|kind| {
			probe = pointer_probe({})
			base = SpecRunner.mount_in(probe, {})
			(d1, form) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "form", rn: 1, hs: [{ event: "submit", handler: 9, kind: 1, policies: 0 }] })
			(d2, input) = Dom.add_node(d1, { ..Dom.empty_node, tag: "input", rn: 2, attrs: [("type", kind)], hs: [{ event: "click", handler: 3, kind: 1, policies: 0 }] })
			(d3, submit) = Dom.add_node(d2, { ..Dom.empty_node, tag: "button", rn: 3, attrs: [("type", "submit")] })
			dom = Dom.bind(Dom.bind(Dom.bind(Dom.insert(Dom.insert(Dom.insert(d3, d3.root, form, Err(End)), form, input, Err(End)), form, submit, Err(End)), 1, form), 2, input), 3, submit)
			after = SpecRunner.press_key(probe, { ..base, dom, focused: input + 1 }, { target: Focused, key: { key: "Enter", code: "Enter", ctrl: False, alt: False, shift: False, meta: False } })?
			Ok(after.inst.map(|event| event.handler))
		},
	) == [Ok([9]), Ok([9]), Ok([9]), Ok([3]), Ok([3])]
}

## Contenteditable focus belongs to an editing host. Inherited, invalid and
## nested editable descendants need tabindex; a false island starts a host.
expect {
	(d1, host) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "div", parent: 1, attrs: [("contenteditable", "TRUE")] })
	(d2, inherited) = Dom.add_node(d1, { ..Dom.empty_node, tag: "span", parent: host + 1 })
	(d3, nested) = Dom.add_node(d2, { ..Dom.empty_node, tag: "div", parent: host + 1, attrs: [("contenteditable", "true")] })
	(d4, invalid) = Dom.add_node(d3, { ..Dom.empty_node, tag: "span", parent: host + 1, attrs: [("contenteditable", "invalid")] })
	(d5, barrier) = Dom.add_node(d4, { ..Dom.empty_node, tag: "div", parent: host + 1, attrs: [("contenteditable", "false")] })
	(d6, island) = Dom.add_node(d5, { ..Dom.empty_node, tag: "div", parent: barrier + 1, attrs: [("contenteditable", "plaintext-only")] })
	(d7, tabbed) = Dom.add_node(d6, { ..Dom.empty_node, tag: "div", parent: host + 1, attrs: [("contenteditable", "true"), ("tabindex", "0")] })
	[host, inherited, nested, invalid, barrier, island, tabbed].map(|i| SpecRunner.focusable_in(d7, i)) == [Bool.True, Bool.False, Bool.False, Bool.False, Bool.False, Bool.True, Bool.True]
}

## Enter and printable input on an editable host are refused by the same
## rule data the browser runner consumes; named inert keys remain available.
expect {
	(d1, host) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "div", attrs: [("contenteditable", "true")] })
	base = { key: "Enter", code: "Enter", ctrl: False, alt: False, shift: False, meta: False }
	[base, { ..base, key: "j", code: "KeyJ" }, { ..base, key: "F2", code: "F2" }].map(|key| SpecRunner.key_unmodelled(d1, host, key)) == [Bool.True, Bool.True, Bool.False]
}

## A bounded scroll observer keeps newest ordinals and never aliases a recycled id.
expect {
	base = SpecRunner.mount_in(pointer_probe({}), {})
	(d1, old) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "button" })
	dom = Dom.bind(Dom.insert(d1, d1.root, old, Err(End)), 1, old)
	var $s = { ..base, dom }
	for _ in List.repeat({}, 4097) {
		$s = SpecRunner.record_scroll($s, old, IntoView({ block: 3, inline: 3, behavior: 0 }))
	}
	retained = $s
	removed = Dom.detach(Dom.forget_subtree(retained.dom, old), old)
	(d2, fresh) = Dom.add_node(removed, { ..Dom.empty_node, tag: "button" })
	rebound = Dom.bind(Dom.insert(d2, d2.root, fresh, Err(End)), 1, fresh)
	maxed = { ..retained, dom: rebound, browser: { ..retained.browser, scroll_count: 18446744073709551615 } }
	exhausted = SpecRunner.record_scroll(maxed, fresh, To({ top: End, left: Keep, behavior: 1 }))
	{
		count: retained.browser.scroll_count,
		length: retained.browser.scrolls.len(),
		oldest: retained.browser.scrolls.first().map_ok(|r| r.ordinal),
		identity: retained.browser.scrolls.last().map_ok(|r| r.target != fresh),
		exhausted: exhausted.browser.scroll_exhausted,
		wrapped: exhausted.browser.scroll_count,
		fault: exhausted.fault,
	} == { count: 4097, length: 4096, oldest: Ok(2), identity: Ok(True), exhausted: True, wrapped: 18446744073709551615, fault: Healthy }
}

## Every private shown decision supersedes an earlier deferred show in its batch.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, dialog) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "dialog" })
	dom = Dom.bind(Dom.insert(d1, d1.root, dialog, Err(End)), 1, dialog)
	prop = |value| SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(6), value)
	done = SpecRunner.drain_focus(program, SpecRunner.take_batch({ ..base, dom }, base.inst, [0].concat(prop("modal")).concat(prop("hidden"))))
	{ shown: Dom.node(done.dom, dialog).shown, tasks: done.browser.ui_tasks.len(), focus: done.focused } == { shown: Hidden, tasks: 0, focus: 0 }
}

## Toggle task coalescing preserves a scalar lifetime and reads state on delivery.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, popover) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "div", rn: 1, attrs: [("popover", "manual")], hs: [{ event: "toggle", handler: 5, kind: 5, policies: 0 }] })
	dom = Dom.bind(Dom.insert(d1, d1.root, popover, Err(End)), 1, popover)
	shown = SpecRunner.change_shown({ ..base, dom }, popover, Popover)
	hidden = SpecRunner.change_shown(shown, popover, Hidden)
	delivered = SpecRunner.deliver_ui(program, SpecRunner.deliver_ui(program, hidden))
	{ tasks: hidden.browser.ui_tasks.count_if(|task| task != Cancelled), pending: Dom.node(delivered.dom, popover).pending_toggle, payloads: delivered.inst.map(|event| event.payload) } == { tasks: 1, pending: False, payloads: [[0]] }
}

## Modal focus, inertness, and non-modal restoration follow native browser defaults.
expect {
	base = SpecRunner.mount_in(pointer_probe({}), {})
	(d1, opener) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "button" })
	(d2, dialog) = Dom.add_node(d1, { ..Dom.empty_node, tag: "dialog" })
	(d3, input) = Dom.add_node(d2, { ..Dom.empty_node, tag: "input" })
	dom = Dom.insert(Dom.insert(Dom.insert(d3, d3.root, opener, Err(End)), d3.root, dialog, Err(End)), dialog, input, Err(End))
	shown = SpecRunner.change_shown({ ..base, dom, focused: opener + 1 }, dialog, Modal)
	hidden = SpecRunner.change_shown(shown, dialog, Hidden)
	inline = SpecRunner.change_shown({ ..base, dom, focused: opener + 1 }, dialog, Open)
	removed = { ..inline, dom: Dom.detach(inline.dom, input), focused: 0 }
	closed_inline = SpecRunner.change_shown(removed, dialog, Hidden)
	{ focused: shown.focused, inert: SpecRunner.reachable(shown, opener), inside: SpecRunner.reachable(shown, input), restored: hidden.focused, removed: closed_inline.focused } == { focused: input + 1, inert: False, inside: True, restored: opener + 1, removed: 0 }
}

## A queued close samples the live reopened dialog in either legal task-source order.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, dialog) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "dialog", rn: 1, shown: Modal, hs: [{ event: "close", handler: 6, kind: 5, policies: 0 }, { event: "toggle", handler: 7, kind: 1, policies: 0 }] })
	dom = Dom.bind(Dom.insert(d1, d1.root, dialog, Err(End)), 1, dialog)
	[[Close(dialog), Toggle(dialog)], [Toggle(dialog), Close(dialog)]].map(
		|tasks| {
			queued = { ..base, dom, browser: { ..base.browser, ui_tasks: tasks } }
			done = SpecRunner.deliver_ui(program, SpecRunner.deliver_ui(program, queued))
			{
				shown: Dom.node(done.dom, dialog).shown,
				close: done.inst.find_first(|event| event.handler == 6).map_ok(|event| event.payload),
				toggles: done.inst.count_if(|event| event.handler == 7),
			}
		},
	) == List.repeat({ shown: Modal, close: Ok([1.U8]), toggles: 1 }, 2)
}

## Observer diagnostics distinguish retained history and exhaustion from app faults.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	old = { ..base, browser: { ..base.browser, scroll_count: 4097 } }
	maxed = { ..base, browser: { ..base.browser, scroll_exhausted: True } }
	{
		old: SpecRunner.one(program, old, ExpectScroll({ ordinal: 1, target: TestId("unused"), kind: IntoView })).map_ok(|_| {}),
		max: SpecRunner.one(program, maxed, ExpectScrolls(0)).map_ok(|_| {}),
		fault: maxed.fault,
	} == { old: Err("scroll ordinal 1 is older than retained history (newest 4096)"), max: Err("scroll observation ordinal exhausted"), fault: Healthy }
}

## An ordinary open attribute keeps raw dialogs non-modal and their controls reachable.
expect {
	base = SpecRunner.mount_in(pointer_probe({}), {})
	(d1, dialog) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "dialog" })
	(d2, input) = Dom.add_node(d1, { ..Dom.empty_node, tag: "input" })
	dom = Dom.insert(Dom.insert(d2, d2.root, dialog, Err(End)), dialog, input, Err(End))
	opened = Dom.set_attr_on(dom, dialog, "open", "true")
	hidden = Dom.remove_attr_on(opened, dialog, "open")
	{ shown: Dom.node(opened, dialog).shown, reached: SpecRunner.reachable({ ..base, dom: opened }, input), focus: SpecRunner.focusable_in(opened, input), hidden: SpecRunner.reachable({ ..base, dom: hidden }, input) } == { shown: Open, reached: True, focus: True, hidden: False }
}

## Intent supersession belongs to one property; an unrelated private row cannot cancel it.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, dialog) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "dialog", attrs: [("popover", "manual")] })
	dom = Dom.bind(Dom.insert(d1, d1.root, dialog, Err(End)), 1, dialog)
	prop = |property, value| SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(property), value)
	done = SpecRunner.drain_focus(program, SpecRunner.take_batch({ ..base, dom }, base.inst, [0].concat(prop(6, "modal")).concat(prop(7, "false"))))
	Dom.node(done.dom, dialog).shown == Modal
}

## A new document cannot inherit a Space activation even when model indices coincide.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, button) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "button", rn: 1, hs: [{ event: "click", handler: 7, kind: 1, policies: 0 }] })
	dom = Dom.bind(Dom.insert(d1, d1.root, button, Err(End)), 1, button)
	old = { ..base, dom, focused: button + 1 }
	(_, context) = SpecRunner.press_down(program, old, { target: Focused, key: { key: " ", code: "Space", ctrl: False, alt: False, shift: False, meta: False } })?
	# Fresh documents may allocate exactly the same model indices and detach counts.
	fresh = { ..base, dom, focused: button + 1, browser: { ..base.browser, doc: 1 } }
	done = SpecRunner.press_up(program, fresh, context)?
	Ok(done.inst.is_empty()) == Ok(True)
}

## Media declarations retain their written order and boot pairs are ordered
## by that catalogue, with unspecified declared queries starting false.
expect {
	query_body = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32([], 2), "wide"), "dark")
	base = pointer_probe({})
	program = { ..base, keys: || SpecRunner.put_section([2, 4, 0, 0, 0, 0, 0, 0, 0, 5, 4, 0, 0, 0, 0, 0, 0, 0], { tag: 6, body: query_body }).concat([10, 2, 0, 0, 0, 110, 1, 11, 4, 0, 0, 0, 0, 0, 0, 0]), init: |boot| ([{ handler: 0.U32, payload: boot }], [], List.repeat(0.U8, 8)) }
	mounted = SpecRunner.mount_in(program, { media: [("dark", True)] })
	{ media: mounted.browser.env.media, flags: mounted.inst.first()?.payload.sublist({ start: 37, len: 2 }) } == { media: [("wide", False), ("dark", True)], flags: [0.U8, 1] }
}

## Observations in a row share its release owner even when their target also
## has a command alias. Releasing that alias alone cannot end the row's work.
expect {
	(d1, root) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "section" })
	(d2, target) = Dom.add_node(d1, { ..Dom.empty_node, tag: "div" })
	placed = Dom.bind(Dom.bind(Dom.insert(Dom.insert(d2, d2.root, root, Err(End)), root, target, Err(End)), 1, root), 2, target)
	observed = Dom.observe(Dom.observe(placed, { owner: root, target, kind: 7 }), { owner: root, target, kind: 8 })
	alias = Dom.release_observed(observed, target)
	released = Dom.release_observed(alias, root)
	removed = Dom.apply(released, SpecRunner.put_u32([0, 5], 1))
	{ live: observed.observed_count, alias_live: alias.observed_count, flags: Dom.node(alias, target).observing, indexed: Dom.node(alias, root).observed, after: removed.observed_count, removed_alias: removed.statics.get(2) } == { live: 2, alias_live: 2, flags: 3.U8, indexed: [target], after: 0, removed_alias: Ok(0) }
}

## Layout reports freeze their payloads and replace only their own source;
## a repeated scroll to the current offset raises no event.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, index) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "div", rn: 1, attrs: [("aria-label", "List")], hs: [{ event: "scroll", handler: 2, kind: 6, policies: 8 }, { event: "size", handler: 3, kind: 7, policies: 8 }, { event: "seen", handler: 4, kind: 8, policies: 40 }] })
	placed = Dom.bind(Dom.insert(d1, d1.root, index, Err(End)), 1, index)
	dom = Dom.observe(Dom.observe(placed, { owner: index, target: index, kind: 7 }), { owner: index, target: index, kind: 8 })
	start = SpecRunner.one(program, { ..base, dom }, HoldReports)?
	a = SpecRunner.one(program, start, ReportSize({ target: Label("List"), width: 1, height: 2 }))?
	b = SpecRunner.one(program, a, ReportSeen({ target: Label("List"), intersecting: True, ratio_permille: 500 }))?
	c = SpecRunner.one(program, b, Scroll({ target: Label("List"), top: 20, left: 0 }))?
	d = SpecRunner.one(program, c, ReportSize({ target: Label("List"), width: 3, height: 4 }))?
	e = SpecRunner.one(program, d, Scroll({ target: Label("List"), top: 40, left: 0 }))?
	f = SpecRunner.one(program, e, Scroll({ target: Label("List"), top: 40, left: 0 }))?
	done = SpecRunner.one(program, f, ReleaseReports)?
	{ held: f.inst, replaced: f.browser.reports.replaced, seen: done.inst, offset: Dom.node(done.dom, index).scroll } == { held: [], replaced: 2, seen: [{ handler: 3.U32, payload: [3.U8, 0, 0, 0, 4, 0, 0, 0] }, { handler: 4, payload: [1, 244, 1] }, { handler: 2, payload: [40, 0, 0, 0, 0, 0, 0, 0] }], offset: { top: 40.U32, left: 0.U32 } }
}

## A scroll command's report raised after a turn waits during a held frame.
## A later occurrence pins it, and its input precedes that occurrence.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, index) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "div", rn: 1, hs: [{ event: "scroll", handler: 2, kind: 6, policies: 8 }] })
	dom = Dom.bind(Dom.insert(d1, d1.root, index, Err(End)), 1, index)
	start = SpecRunner.one(program, { ..base, dom }, HoldReports)?
	command = SpecRunner.perform_scroll(program, start, index, To({ top: Px(20), left: Keep, behavior: 1 }))
	waiting = SpecRunner.drain_focus(program, command)
	done = SpecRunner.send(program, waiting, SpecRunner.fx_node, 9, [])
	{ waiting: waiting.inst, queued: waiting.event_queue.len(), shown: done.inst, held: done.browser.reports.held } == { waiting: [], queued: 1, shown: [{ handler: 2.U32, payload: [20.U8, 0, 0, 0, 0, 0, 0, 0] }, { handler: 9, payload: [] }], held: True }
}

## End and descendant reveal need geometry, so refusing their native proof
## is a step failure while the app remains healthy. Revealing the scroller
## itself does not move its own viewport and remains allowed.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, scroller) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "div", rn: 1, hs: [{ event: "scroll", handler: 2, kind: 6, policies: 8 }] })
	(d2, child) = Dom.add_node(d1, { ..Dom.empty_node, tag: "p" })
	dom = Dom.bind(Dom.insert(Dom.insert(d2, d2.root, scroller, Err(End)), scroller, child, Err(End)), 1, scroller)
	start = { ..base, dom }
	ended = SpecRunner.perform_scroll(program, start, scroller, To({ top: End, left: Keep, behavior: 1 }))
	revealed = SpecRunner.perform_scroll(program, start, child, IntoView({ block: 3, inline: 3, behavior: 1 }))
	self = SpecRunner.perform_scroll(program, start, scroller, IntoView({ block: 3, inline: 3, behavior: 1 }))
	{ end_refused: !ended.browser.scroll_error.is_empty(), child_refused: !revealed.browser.scroll_error.is_empty(), self_allowed: self.browser.scroll_error.is_empty(), faults: [ended.fault, revealed.fault, self.fault] } == { end_refused: True, child_refused: True, self_allowed: True, faults: [Healthy, Healthy, Healthy] }
}

## An ordinary text scroll remains an occurrence during a held frame: it
## delivers older reports before its empty payload and keeps the hold active.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, index) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "div", rn: 1, attrs: [("aria-label", "List")], hs: [{ event: "scroll", handler: 2, kind: 1, policies: 0 }, { event: "size", handler: 3, kind: 7, policies: 8 }] })
	placed = Dom.bind(Dom.insert(d1, d1.root, index, Err(End)), 1, index)
	dom = Dom.observe(placed, { owner: index, target: index, kind: 7 })
	held = SpecRunner.one(program, { ..base, dom }, HoldReports)?
	pending = SpecRunner.one(program, held, ReportSize({ target: Label("List"), width: 10, height: 20 }))?
	done = SpecRunner.one(program, pending, Scroll({ target: Label("List"), top: 30, left: 0 }))?
	{ seen: done.inst, held: done.browser.reports.held, queued: done.event_queue.len() } == { seen: [{ handler: 3.U32, payload: [10.U8, 0, 0, 0, 20, 0, 0, 0] }, { handler: 2, payload: [] }], held: True, queued: 0 }
}

## An occurrence pins the reports ahead of it, while a scroll report its own
## command raises waits behind it for the next released frame.
expect {
	base_program = pointer_probe({})
	command = SpecRunner.put_u32(SpecRunner.put_u32([18, 7], 1).append(3), 40).concat([0, 1])
	program = { ..base_program, event: |seen, _buf, _work, _node, handler, payload| (seen.append({ handler, payload }), if (handler == 9) [0].concat(command) else [], List.repeat(0.U8, 8)) }
	base = SpecRunner.mount_in(program, {})
	(d1, index) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "div", rn: 1, hs: [{ event: "scroll", handler: 2, kind: 6, policies: 8 }] })
	dom = Dom.bind(Dom.insert(d1, d1.root, index, Err(End)), 1, index)
	held = SpecRunner.one(program, { ..base, dom }, HoldReports)?
	older = SpecRunner.set_scroll(program, held, { target: index, top: 20, left: 0 })
	after_occurrence = SpecRunner.send(program, older, SpecRunner.fx_node, 9, [])
	done = SpecRunner.one(program, after_occurrence, ReleaseReports)?
	{ at_occurrence: after_occurrence.inst, waiting: after_occurrence.event_queue.len(), after_frame: done.inst } == { at_occurrence: [{ handler: 2.U32, payload: [20.U8, 0, 0, 0, 0, 0, 0, 0] }, { handler: 9, payload: [] }], waiting: 1, after_frame: [{ handler: 2, payload: [20, 0, 0, 0, 0, 0, 0, 0] }, { handler: 9, payload: [] }, { handler: 2, payload: [40, 0, 0, 0, 0, 0, 0, 0] }] }
}

## Injected observations require live declarations, and media facts cannot
## silently create a query the program never declared.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	(d1, index) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "div", rn: 1, attrs: [("aria-label", "List")] })
	dom = Dom.bind(Dom.insert(d1, d1.root, index, Err(End)), 1, index)
	state = { ..base, dom }
	spec = Scm.parse("(test \"undeclared\" (setup (initial-media \"dark\" true)) (steps (mark-metrics)))")?
	{
		size: SpecRunner.one(program, state, ReportSize({ target: Label("List"), width: 10, height: 20 })).map_ok(|_| {}),
		seen: SpecRunner.one(program, state, ReportSeen({ target: Label("List"), intersecting: True, ratio_permille: 500 })).map_ok(|_| {}),
		media: SpecRunner.one(program, state, SetMedia({ query: "dark", matches: True })).map_ok(|_| {}),
		boot: SpecRunner.start(program, spec).map_ok(|_| {}),
	} == {
		size: Err("(label \"List\") has no live size observation"),
		seen: Err("(label \"List\") has no live seen observation"),
		media: Err("set-media query \"dark\" is not declared"),
		boot: Err("initial-media query \"dark\" is not declared"),
	}
}

## A declared media source uses the shared report queue: newest matches
## replace earlier ones, unchanged facts raise nothing, and cancellation
## drops waiting answers while retaining the query's environment value.
expect {
	base_program = pointer_probe({})
	declarations = SpecRunner.put_section([2, 4, 0, 0, 0, 0, 0, 0, 0, 5, 4, 0, 0, 0, 0, 0, 0, 0], { tag: 6, body: SpecRunner.put_str(SpecRunner.put_u32([], 1), "dark") }).concat([10, 2, 0, 0, 0, 110, 1, 11, 4, 0, 0, 0, 0, 0, 0, 0])
	listen = SpecRunner.put_str(SpecRunner.put_u32([13], 1).append(16), "dark")
	program = { ..base_program, keys: || declarations, init: |_boot| ([], [0].concat(listen), List.repeat(0.U8, 8)) }
	base = SpecRunner.mount_in(program, {})
	held = SpecRunner.one(program, base, HoldReports)?
	first = SpecRunner.one(program, held, SetMedia({ query: "dark", matches: True }))?
	second = SpecRunner.one(program, first, SetMedia({ query: "dark", matches: False }))?
	unchanged = SpecRunner.one(program, second, SetMedia({ query: "dark", matches: False }))?
	answered = SpecRunner.one(program, unchanged, ReleaseReports)?
	waiting = SpecRunner.one(program, SpecRunner.one(program, answered, HoldReports)?, SetMedia({ query: "dark", matches: True }))?
	cancelled = SpecRunner.take_batch(waiting, waiting.inst, SpecRunner.put_u32([0, 14], 1))
	done = SpecRunner.one(program, cancelled, ReleaseReports)?
	{ seen: done.inst, replacements: done.browser.reports.replaced, sources: done.browser.report_sources.len(), subscriptions: done.browser.subs.len(), media: done.browser.env.media } == { seen: [{ handler: 1.U32, payload: [22.U8, 0] }], replacements: 1, sources: 0, subscriptions: 0, media: [("dark", True)] }
}

## Marked batches start non-node effects before references, preserving order
## within each class. Ordinary batches keep their original stream order.
expect {
	base = SpecRunner.fresh(0.U64, SpecRunner.fresh_browser({}))
	(d, target) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "button" })
	dom = Dom.bind(Dom.insert(d, d.root, target, Err(End)), 1, target)
	commands = SpecRunner.put_u32([18, 1], 1).concat(SpecRunner.put_str([17], "early"))
	marked = SpecRunner.take_batch({ ..base, dom }, 0, [1].concat(commands).concat([24, 0, 0, 0, 0]))
	ordinary = SpecRunner.take_batch({ ..base, dom }, 0, [0].concat(commands))
	ref = Ref({ node: 1, target, action: Focus(1) })
	{ marked: marked.after_batch, ordinary: ordinary.after_batch } == { marked: [Effect(Title("early")), ref], ordinary: [ref, Effect(Title("early"))] }
}

## Assertion failures distinguish an unperformed ordinal, an evicted record
## and exhaustion of observation, without turning any into an app fault.
expect {
	program = pointer_probe({})
	base = SpecRunner.mount_in(program, {})
	dom = Dom.transition(base.dom, ["shelf"])
	seen = { ..base, dom }
	evicted = { ..seen, dom: { ..dom, transitions: { ..dom.transitions, records: Dict.empty() } } }
	exhausted = { ..seen, dom: { ..dom, transitions: { ..dom.transitions, exhausted: True } } }
	{
		seen: SpecRunner.one(program, seen, ExpectTransition({ at: 1, types: ["shelf"] })).map_ok(|_| {}),
		missing: SpecRunner.one(program, seen, ExpectTransition({ at: 2, types: [] })).map_ok(|_| {}),
		evicted: SpecRunner.one(program, evicted, ExpectTransition({ at: 1, types: [] })).map_ok(|_| {}),
		exhausted: SpecRunner.one(program, exhausted, ExpectTransitions(0)).map_ok(|_| {}),
	} == {
		seen: Ok({}),
		missing: Err("transition ordinal 2 was not performed"),
		evicted: Err("transition ordinal 1 is unavailable in retained history (newest 4096, at most 1048576 encoded type bytes)"),
		exhausted: Err("transition observation ordinal exhausted"),
	}
}

## Clock steps change only the next sampled input. They cannot route a turn
## or modify already-recorded boot facts, and overflow remains a runner error.
expect {
	program = report_probe({})
	start = SpecRunner.mount_in(program, { now_ms: -1 })
	set = SpecRunner.one(program, start, SetTime(-9223372036854775808))?
	advanced = SpecRunner.one(program, set, AdvanceTime(18446744073709551615))?
	{ seen: advanced.inst, now: advanced.browser.env.now_ms, overflow: SpecRunner.one(program, advanced, AdvanceTime(1)).is_err() } == { seen: [], now: 9223372036854775807, overflow: True }
}

## Failed writes share one bounded task FIFO; no subscriber means no retained work.
expect {
	initial = { ..SpecRunner.fresh_browser({}), settings: { local_full: True, session_full: False, clipboard_denied: False, max_paste: 4194304 } }
	subscribed = SpecRunner.absorb(initial, [StorageFailures(1)])
	full = SpecRunner.absorb(subscribed, List.repeat(Set("draft", "value"), 4096))
	overflow = SpecRunner.absorb(full, [Set("draft", "another")])
	canceled = SpecRunner.absorb(full, [Cancel(1), StorageFailures(2), Set("draft", "new")])
	combined = SpecRunner.absorb_limit(subscribed, List.repeat(Set("draft", "value"), 4096), 4095)
	silent = SpecRunner.absorb(initial, [Set("draft", "value")])
	{ full: SpecRunner.failure_tasks(full), fits: full.deferred_error.is_empty(), overflow: !overflow.deferred_error.is_empty(), retained: SpecRunner.failure_tasks(overflow), freed: SpecRunner.failure_tasks(canceled), successor: canceled.deferred_error.is_empty(), combined: !combined.deferred_error.is_empty(), silent: silent.gets.is_empty() } == { full: 4096, fits: True, overflow: True, retained: 4096, freed: 1, successor: True, combined: True, silent: True }
}

## The clipboard's observation ordinal can exhaust without refusing the actual copy.
expect {
	program = report_probe({})
	state = SpecRunner.mount_in(program, {})
	before = { ..state.browser, clipboard: { text: "old", html: "", writes: 18446744073709551614, exhausted: False } }
	last = SpecRunner.absorb(before, [Clipboard(1, { text: "last counted", html: Plain })])
	exhausted = SpecRunner.absorb(last, [Clipboard(2, { text: "still copied", html: Html("<p>still copied</p>") })])
	observed = { ..state, browser: exhausted }
	{ last: last.clipboard.writes, last_valid: !last.clipboard.exhausted, text: exhausted.clipboard.text, exhausted: exhausted.clipboard.exhausted, callbacks: exhausted.gets.len(), assertion: SpecRunner.one(program, observed, ExpectClipboard("still copied")).is_err(), fault: observed.fault } == { last: 18446744073709551615, last_valid: True, text: "still copied", exhausted: True, callbacks: 2, assertion: True, fault: Healthy }
}

## A canceled clipboard answer is forgotten after the write has happened.
expect {
	browser = SpecRunner.absorb(SpecRunner.fresh_browser({}), [Clipboard(1, { text: "kept", html: Plain }), Cancel(1)])
	{ text: browser.clipboard.text, writes: browser.clipboard.writes, callbacks: browser.gets.len() } == { text: "kept", writes: 1, callbacks: 0 }
}

## Sticky leave activation survives consumption of a CloseWatcher opportunity.
expect {
	program = report_probe({})
	initial = SpecRunner.mount_in(program, {})
	activated = SpecRunner.activate_step(initial, Press({ target: Focused, key: { key: "Enter", code: "Enter", ctrl: False, alt: False, shift: False, meta: False } }))
	consumed = { ..activated, browser: { ..activated.browser, cancel_allowed: False, guard: True } }
	{ stays: SpecRunner.one(program, consumed, LeavePage({ url: "/next", outcome: Stay })).is_ok(), ordinary: SpecRunner.one(program, consumed, Navigate("/next")).is_err(), no_question: SpecRunner.one(program, consumed, LeavePage({ url: "/next", outcome: Unasked })).is_err() } == { stays: True, ordinary: True, no_question: True }
}

## A supported same-origin navigation inherits sticky activation but resets
## the CloseWatcher opportunity; a later dirty document can therefore ask again.
expect {
	program = report_probe({})
	initial = SpecRunner.mount_in(program, {})
	activated = SpecRunner.activate_step(initial, Press({ target: Focused, key: { key: "Enter", code: "Enter", ctrl: False, alt: False, shift: False, meta: False } }))
	next = SpecRunner.one(program, activated, Navigate("/next"))?
	guarded = { ..next, browser: { ..next.browser, guard: True } }
	held = SpecRunner.one(program, guarded, HoldReports)?
	{ fresh: initial.browser.sticky_activation, inherited: next.browser.sticky_activation, close_allowance: next.browser.cancel_allowed, document: next.browser.doc, asks: SpecRunner.one(program, guarded, LeavePage({ url: "/later", outcome: Stay })).is_ok(), held_refused: SpecRunner.one(program, held, LeavePage({ url: "/later", outcome: Stay })).is_err() } == { fresh: False, inherited: True, close_allowance: False, document: 1, asks: True, held_refused: True }
}

## A scripted guarded stay still rejects a physical press in progress before
## routing or draining anything, just as the Chrome navigation driver does.
expect {
	program = report_probe({})
	initial = SpecRunner.mount_in(program, {})
	pointer = { id: 1.U32, kind: Mouse, button: Main, modifiers: 0.U8, primary: True, down: 0.U64, capture: 0.U64, moved: False, suppress_mouse: False, at: Outside }
	pressed = { ..initial, browser: { ..initial.browser, pointers: initial.browser.pointers.insert(1, pointer), guard: True, sticky_activation: True } }
	SpecRunner.one(program, pressed, LeavePage({ url: "/next", outcome: Stay })).is_err()
}

## A nested click handler can follow its ancestor link, so a guarded walk
## excludes that span even before the first activation, retaining ordinary buttons.
expect {
	base = SpecRunner.fresh(0.U64, SpecRunner.fresh_browser({}))
	(first, anchor) = Dom.add_node(base.dom, { ..Dom.empty_node, tag: "a", attrs: [("href", "/next")] })
	(second, span) = Dom.add_node(first, { ..Dom.empty_node, tag: "span", hs: [{ event: "click", handler: 0, kind: 1, policies: 0 }] })
	(third, button) = Dom.add_node(second, { ..Dom.empty_node, tag: "button", hs: [{ event: "click", handler: 1, kind: 1, policies: 0 }] })
	dom = Dom.insert(Dom.insert(Dom.insert(third, third.root, anchor, Err(End)), anchor, span, Err(End)), third.root, button, Err(End))
	guarded = { ..base, dom, browser: { ..base.browser, guard: True } }
	{ ordinary: SpecRunner.candidates(dom), guarded: SpecRunner.walk_candidates(guarded), sticky: guarded.browser.sticky_activation } == { ordinary: [(span, "click"), (button, "click")], guarded: [(button, "click")], sticky: False }
}

## A getter-unavailable fixture still permits the other document's write,
## but cannot identify its local area for reports; its backing value is retained.
expect {
	program = report_probe({})
	initial = SpecRunner.mount_in(program, { storage_available: False })
	subscribed = { ..initial, browser: SpecRunner.absorb(initial.browser, [StorageSub(3, "document")]) }
	changed = SpecRunner.one(program, subscribed, StorageElsewhere({ key: "document", value: "remote" }))?
	{ pairs: changed.browser.env.storage, available: changed.browser.env.storage_available, delivered: changed.inst } == { pairs: [("document", "remote")], available: False, delivered: [] }
}

## One failure task batches its original recipients ahead of an already
## scheduled read; a failed write raised by its first answer waits for the next task.
expect {
	base_program = report_probe({})
	program = {
		..base_program,
		event: |seen, _buffer, _work, _node, id, payload| {
			commands = if (seen.is_empty()) [0, 16, 1, 1, 0, 0, 0, 'd', 1, 0, 0, 0, 'x'] else []
			(seen.append({ id, payload }), commands, List.repeat(0.U8, 8))
		},
	}
	initial = SpecRunner.mount_in(program, {})
	configured = { ..initial.browser, settings: { ..initial.browser.settings, local_full: True } }
	browser = SpecRunner.absorb(configured, [StorageFailures(9), Set("a", "x"), Get(10, "missing"), Set("c", "x")])
	queued = { ..initial, browser }
	done = SpecRunner.drain_focus(program, SpecRunner.answer_gets(program, queued))
	{ delivered: done.inst, remaining: SpecRunner.failure_tasks(done.browser), scheduled: done.browser.failure_scheduled, active: done.browser.failure_active } == {
		delivered: [{ id: 9, payload: [25, 1, 1, 'a'] }, { id: 9, payload: [25, 1, 1, 'c'] }, { id: 10, payload: [4] }, { id: 9, payload: [25, 1, 1, 'd'] }],
		remaining: 0,
		scheduled: False,
		active: False,
	}
}

## A timeout stub changes only a network result’s ordering; running an unrelated
## timer remains an occurrence that delivers earlier held reports first.
expect {
	browser = SpecRunner.fresh_browser({})
	timer = SpecRunner.fresh({}, { ..browser, stub: Staged(Reject({ kind: Timeout, detail: "" })), issued: [1], pending: [{ id: 1, url: "timer", body: "", kind: TimerRequest }] })
	network = { ..timer, browser: { ..timer.browser, pending: [{ id: 1, url: "/request", body: "", kind: HttpRequest }] } }
	{ timer: SpecRunner.is_occurrence(timer, RunEffect(1)), network: SpecRunner.is_occurrence(network, RunEffect(1)), unissued: SpecRunner.is_occurrence(network, RunEffect(2)) } == { timer: True, network: False, unissued: True }
}
