import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Port
import pf.Wire

## Ports test app: one port of every shape, used by effect sites whose
## results are appended to the log (`test-id "log"`).
## - "Send" sends a command on `log`.
## - "Get" calls `get` (a 1 s timeout) for key `kN` from a `latest` site, so
##   a second press stops the first call.
## - "Panel" mounts a `when` branch that calls `get` at mount and subscribes
##   to `ticks` (`Latest`); closing it disposes both: the call is kept and
##   answered to the app, the subscription is cancelled.
## - "Feed" toggles a subscription to `feed` (`Every(4)`) with argument
##   `"news"`.
## - "Echo" calls `echo` with "Size" bytes (`Wire.Bytes`) and logs the
##   length and the first and last byte of the answer.
## - "Inspect" calls `inspect` with the first chosen file; "Make" calls
##   `make`, whose JavaScript answers a new `File`, kept in the state.
## - "Undeclared" sends on a port the program does not declare, and "Wrong"
##   subscribes to the call port `get`: both are contract errors.
PortsApp := [].{
	S : {
		sends : U64,
		gets : U64,
		panel : Bool,
		feed : Bool,
		size : Str,
		echoes : Press,
		inspects : U64,
		makes : U64,
		chosen : List(Engine.File),
		made : List(Engine.File),
		undeclared : U64,
		wrong : U64,
		log : List(Str),
	}

	## How many times "Echo" was pressed and the size at the last press.
	Press : { n : U64, size : Str }

	Ctx : In(Root, S)

	initial : S
	initial = { sends: 0, gets: 0, panel: False, feed: False, size: "4", echoes: { n: 0, size: "" }, inspects: 0, makes: 0, chosen: [], made: [], undeclared: 0, wrong: 0, log: [] }

	log : Port.Command({ text : Str })
	log = Port.command({ name: "test.roc-signals/log" })

	get : Port.Call({ key : Str }, { value : Str })
	get = Port.call({ name: "test.roc-signals/get", timeout: Ms(1000) })

	echo : Port.Call(Wire.Bytes, Wire.Bytes)
	echo = Port.call({ name: "test.roc-signals/echo" })

	inspect : Port.Call(Engine.File, { name : Str, size : U64 })
	inspect = Port.call({ name: "test.roc-signals/inspect" })

	make : Port.Call(Str, Engine.File)
	make = Port.call({ name: "test.roc-signals/make" })

	ticks : Port.Subscription({}, U64)
	ticks = Port.subscription({ name: "test.roc-signals/ticks", delivery: Latest })

	feed : Port.Subscription(Str, Str)
	feed = Port.subscription({ name: "test.roc-signals/feed", delivery: Every(4) })

	error : Port.Error -> Str
	error = |e| match e {
		Refused => "refused"
		Timeout => "timeout"
		Threw(text) => "threw ${text}"
		TooLarge => "too large"
		Closed => "closed"
		Undecodable(why) => "undecodable ${why}"
	}

	shown : Try(a, Port.Error), (a -> Str) -> Str
	shown = |r, ok| match r {
		Ok(value) => ok(value)
		Err(e) => PortsApp.error(e)
	}

	log_line : S, Str -> S
	log_line = |s, line| { ..s, log: s.log.append(line) }

	echoed : Wire.Bytes -> Str
	echoed = |bytes| {
		list = bytes.to_list()
		"${list.len().to_str()} ${(list.first() ?? 0).to_str()} ${(list.last() ?? 0).to_str()}"
	}

	## `n` bytes counting up from 1, built at run time.
	payload : U64 -> Wire.Bytes
	payload = |n| {
		var $b = List.with_capacity(n)
		var $i = 0.U64
		while $i < n {
			$b = $b.append(($i + 1).to_u8_wrap())
			$i = $i + 1
		}
		Wire.Bytes.from_list($b)
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.signal()
		Html.div(
			"ports",
			[
				Html.button("Send", [], st.update(|s| { ..s, sends: s.sends + 1 })),
				Engine.watch_changes(v.map(|s| s.sends), |n| [PortsApp.log.send({ text: "hello ${n.to_str()}" })], Engine.ignore({})),
				Html.button("Get", [], st.update(|s| { ..s, gets: s.gets + 1 })),
				Engine.watch_latest(
					v.map(|s| s.gets),
					|n| if (n == 0) [] else [PortsApp.get.request({ key: "k${n.to_str()}" })],
					st.on_result(|s, n, r| PortsApp.log_line(s, "get k${n.to_str()}:${PortsApp.shown(PortsApp.get.result(r), |a| a.value)}")),
				),
				Html.button("Panel", [], st.update(|s| { ..s, panel: !s.panel })),
				Engine.when(
					v.map(|s| s.panel),
					|| Engine.element(
						"section",
						[Html.aria_label("panel")],
						[
							Engine.watch(Engine.const({}), |_| [PortsApp.get.request({ key: "panel" })], st.on_result(|s, _, r| PortsApp.log_line(s, "panel get:${PortsApp.shown(PortsApp.get.result(r), |a| a.value)}"))),
							Engine.watch(Engine.const({}), |_| [PortsApp.ticks.subscribe({})], st.on_result(|s, _, r| PortsApp.log_line(s, "tick:${PortsApp.shown(PortsApp.ticks.message(r), |n| n.to_str())}"))),
							Engine.text("panel open"),
						],
					),
					|| Engine.text(""),
				),
				Html.button("Feed", [], st.update(|s| { ..s, feed: !s.feed })),
				Engine.watch_latest(
					v.map(|s| s.feed),
					|on| if (on) [PortsApp.feed.subscribe("news")] else [],
					st.on_result(|s, _, r| PortsApp.log_line(s, "feed:${PortsApp.shown(PortsApp.feed.message(r), |t| t)}")),
				),
				Html.text_input(Engine.const("Size"), "text", v.map(|s| s.size), [], st.set_value(|s, t| { ..s, size: t })),
				Html.button("Echo", [], st.update(|s| { ..s, echoes: { n: s.echoes.n + 1, size: s.size } })),
				Engine.watch_changes(
					v.map(|s| s.echoes),
					|p| [PortsApp.echo.request(PortsApp.payload(U64.from_str(p.size) ?? 0))],
					st.on_result(|s, _, r| PortsApp.log_line(s, "echo:${PortsApp.shown(PortsApp.echo.result(r), PortsApp.echoed)}")),
				),
				Html.file_input(Engine.const("Upload"), {}, st.on_files(|s, { files, refused: _ }| { ..s, chosen: files })),
				Html.button("Inspect", [], st.update(|s| { ..s, inspects: s.inspects + 1 })),
				Engine.watch_changes(
					v.map(|s| (s.inspects, s.chosen)),
					|(_, chosen)| match chosen.first() {
						Ok(file) => [PortsApp.inspect.request(file)]
						Err(_) => []
					},
					st.on_result(|s, _, r| PortsApp.log_line(s, "inspect:${PortsApp.shown(PortsApp.inspect.result(r), |a| "${a.name} ${a.size.to_str()}")}")),
				),
				Html.button("Make", [], st.update(|s| { ..s, makes: s.makes + 1 })),
				Engine.watch_changes(
					v.map(|s| s.makes),
					|n| [PortsApp.make.request("made ${n.to_str()}")],
					st.on_result(
						|s, _, r| match PortsApp.make.result(r) {
							Ok(file) => PortsApp.log_line({ ..s, made: s.made.append(file) }, "make:${file.name()} ${file.size().to_str()}")
							Err(e) => PortsApp.log_line(s, "make:${PortsApp.error(e)}")
						},
					),
				),
				Html.button("Forget", [], st.update(|s| { ..s, made: [], chosen: [] })),
				Html.button("Undeclared", [], st.update(|s| { ..s, undeclared: s.undeclared + 1 })),
				Engine.watch_changes(v.map(|s| s.undeclared), |_| [PortCommand({ port: "test.roc-signals/undeclared", message: { json: "null", blobs: [], files: [] } })], Engine.ignore({})),
				Html.button("Wrong", [], st.update(|s| { ..s, wrong: s.wrong + 1 })),
				Engine.watch_changes(v.map(|s| s.wrong), |_| [PortSubscribe({ port: "test.roc-signals/get", message: { json: "{}", blobs: [], files: [] } })], Engine.ignore({})),
				Html.p_s(v.map(|s| Str.join_with(s.log, "|")), [Engine.test_id("log")]),
			],
		)
	}

	## The program, with every port it uses declared.
	program : Engine.Program
	program =
		Engine.program(|| Engine.state(PortsApp.initial, |st| PortsApp.view(st)))
			.with_ports([
				PortsApp.log.registration(),
				PortsApp.get.registration(),
				PortsApp.echo.registration(),
				PortsApp.inspect.registration(),
				PortsApp.make.registration(),
				PortsApp.ticks.registration(),
				PortsApp.feed.registration(),
			])
}
