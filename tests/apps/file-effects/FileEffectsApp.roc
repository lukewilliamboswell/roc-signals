import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html

## File effects test app: operations on a file the user gave the app, run
## where the file lives, and reads that bring its bytes into the page.
## - "Upload" is a file input that takes several files; "Clear" lets them go.
## - "Read text" and "Read bytes" read the first file into the page,
##   accepting the default 8 MiB; "Read large" reads it as bytes accepting
##   64 MiB; "Read tail" reads the second half of it as bytes, and "Read
##   cut" its second byte alone as text (which cuts a two-byte character in
##   two). The answer
##   is shown in `test-id "read"`: the text, or the byte count and byte sum,
##   or the typed failure. "Forget" gives the read up.
## - "Panel" mounts a section that reads the first file's text as it mounts;
##   closing the panel disposes the read with it.
## - "Send" and "Send tail" POST the first file, or its second half, to
##   `/upload` (`test-id "sent"`); "Send panel" mounts a section that sends
##   the first file as it mounts, whose answer is kept in the app's state
##   (`test-id "panel-sent"`) even when the section has been closed.
## - "Digest" and "Digest tail" show the SHA-256 digest of the first file or
##   its second half, in hex (`test-id "digest"`).
## - "Show" asks for a URL that shows the first file and links to it
##   (`test-id "preview"`, `test-id "shown"`); "Hide" gives it up.
FileEffectsApp := [].{
	S : { files : List(File), read : Ask, panel : Bool, send : Pick, send_panel : Bool, panel_sent : Str, digest : Pick, show : Pick }

	## What the page was last asked to read: nothing, or a file as text or
	## as bytes, or as bytes accepting a large file.
	Ask : [Skip, Bytes(File), Text(File), Large(File)]

	## A file an operation was last asked for, or none.
	Pick : [Skip, Run(File)]

	## The read's answer, as the page shows it.
	Shown : [NotRead, Reading, GotBytes(Try(List(U8), Engine.FileError)), GotText(Try(Str, Engine.FileError))]

	## An operation's state: not asked, waiting, or its answer as text.
	Op : [Idle, Waiting, Answered(Str)]

	Ctx : In(Root, S)

	describe : File -> Str
	describe = |f| "${f.name()}:${f.size().to_str()}:${f.mime()}"

	listing : List(File) -> Str
	listing = |files| if (files.is_empty()) "none" else Str.join_with(files.map(FileEffectsApp.describe), "|")

	received : S, Engine.Received -> S
	received = |s, { files, refused: _ }| { ..s, files: s.files.concat(files) }

	## Ask to read the first file, or a range of it, as `make` says.
	ask_first : S, (File -> Ask) -> S
	ask_first = |s, make| match s.files {
		[first, ..] => { ..s, read: make(first) }
		[] => s
	}

	## The first file, or a range of it, for an operation.
	pick_first : List(File), (File -> File) -> Pick
	pick_first = |files, range| match files {
		[first, ..] => Run(range(first))
		[] => Skip
	}

	whole : File -> File
	whole = |f| f

	tail_of : File -> File
	tail_of = |f| f.slice({ start: f.size() / 2, len: f.size() - f.size() / 2 })

	sum : List(U8) -> U64
	sum = |bytes| bytes.fold(0, |acc, b| acc + b.to_u64())

	hex : List(U8) -> Str
	hex = |bytes| {
		digits = "0123456789abcdef".to_utf8()
		var $out = []
		for b in bytes {
			$out = $out.append(digits.get(b.shr_zf_wrap(4).to_u64()) ?? 48).append(digits.get(b.bitwise_and(15).to_u64()) ?? 48)
		}
		Str.from_utf8($out) ?? ""
	}

	show : Shown -> Str
	show = |shown| match shown {
		NotRead => "not read"
		Reading => "reading"
		GotBytes(Ok(bytes)) => "bytes ${bytes.len().to_str()} sum ${FileEffectsApp.sum(bytes).to_str()}"
		GotText(Ok(text)) => "text ${text}"
		GotBytes(Err(e)) => "failed ${Str.inspect(e)}"
		GotText(Err(e)) => "failed ${Str.inspect(e)}"
	}

	show_op : Op -> Str
	show_op = |op| match op {
		Idle => "idle"
		Waiting => "waiting"
		Answered(text) => text
	}

	sent : Res -> Str
	sent = |res| match Engine.http_text(res) {
		Ok(body) => "sent ${body}"
		Err(e) => "send failed ${Str.inspect(e)}"
	}

	Res : Engine.Res

	## A `resource` that reads what `ask` names into the page.
	reader : Engine.Val(ctx, Ask), (Engine.Val(In(ctx, Shown), Shown) -> Elem(In(ctx, Shown))) -> Elem(ctx)
	reader = |ask, body|
		Engine.resource(
			ask,
			{
				init: NotRead,
				pending: |_, a| match a {
					Skip => NotRead
					_ => Reading
				},
				plan: |a| match a {
					Bytes(f) => [f.read_bytes({})]
					Text(f) => [f.read_utf8({})]
					Large(f) => [f.read_bytes({ max_bytes: 64 * 1024 * 1024 })]
					Skip => []
				},
				resolve: |_, a, res| match a {
					Bytes(_) | Large(_) => GotBytes(Engine.file_bytes(res))
					Text(_) => GotText(Engine.file_text(res))
					Skip => NotRead
				},
			},
			body,
		)

	## A `resource` that runs `request` on the file `pick` names and shows its
	## answer with `answer`.
	operation : Engine.Val(ctx, Pick), (File -> Engine.Req), (Res -> Str), (Engine.Val(In(ctx, Op), Op) -> Elem(In(ctx, Op))) -> Elem(ctx)
	operation = |pick, request, answer, body|
		Engine.resource(
			pick,
			{
				init: Idle,
				pending: |_, p| match p {
					Skip => Idle
					Run(_) => Waiting
				},
				plan: |p| match p {
					Run(f) => [request(f)]
					Skip => []
				},
				resolve: |_, _, res| Answered(answer(res)),
			},
			body,
		)

	upload : File -> Engine.Req
	upload = |f| f.upload({ url: "/upload", headers: [("x-name", f.name())] })

	digested : Res -> Str
	digested = |res| match Engine.file_digest(res) {
		Ok(bytes) => "sha256 ${FileEffectsApp.hex(bytes)}"
		Err(e) => "digest failed ${Str.inspect(e)}"
	}

	shown_url : Res -> Str
	shown_url = |res| match Engine.file_url(res) {
		Ok(url) => url
		Err(e) => "failed ${Str.inspect(e)}"
	}

	url_state : Op -> Str
	url_state = |op| match op {
		Answered(url) if url.starts_with("blob:") => "shown"
		other => FileEffectsApp.show_op(other)
	}

	url_of : Op -> Str
	url_of = |op| match op {
		Answered(url) if url.starts_with("blob:") => url
		_ => ""
	}

	first_text : List(File) -> Ask
	first_text = |files| match files {
		[first, ..] => Text(first)
		[] => Skip
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"file-effects",
			[
				Html.file_input(Engine.const("Upload"), { selection: Multiple }, st.on_files(FileEffectsApp.received)),
				Html.p_v(v.map(|s| FileEffectsApp.listing(s.files)), [Engine.test_id("files")]),
				Html.button("Clear", [], st.update(|s| { ..s, files: [] })),
				Html.button("Read text", [], st.update(|s| FileEffectsApp.ask_first(s, |f| Text(f)))),
				Html.button("Read bytes", [], st.update(|s| FileEffectsApp.ask_first(s, |f| Bytes(f)))),
				Html.button("Read large", [], st.update(|s| FileEffectsApp.ask_first(s, |f| Large(f)))),
				Html.button("Read tail", [], st.update(|s| FileEffectsApp.ask_first(s, |f| Bytes(FileEffectsApp.tail_of(f))))),
				Html.button("Read cut", [], st.update(|s| FileEffectsApp.ask_first(s, |f| Text(f.slice({ start: 1, len: 1 }))))),
				Html.button("Forget", [], st.update(|s| { ..s, read: Skip })),
				FileEffectsApp.reader(v.map(|s| s.read), |r| Html.p_v(r.map(FileEffectsApp.show), [Engine.test_id("read")])),
				Html.button("Panel", [], st.update(|s| { ..s, panel: !s.panel })),
				Engine.when(
					v.map(|s| s.panel),
					|| Engine.element(
						"section",
						[Html.aria_label("panel")],
						[FileEffectsApp.reader(v.map(|s| FileEffectsApp.first_text(s.files)), |r| Html.p_v(r.map(FileEffectsApp.show), [Engine.test_id("panel-read")]))],
					),
					|| Engine.text(""),
				),
				Html.button("Send", [], st.update(|s| { ..s, send: FileEffectsApp.pick_first(s.files, FileEffectsApp.whole) })),
				Html.button("Send tail", [], st.update(|s| { ..s, send: FileEffectsApp.pick_first(s.files, FileEffectsApp.tail_of) })),
				FileEffectsApp.operation(v.map(|s| s.send), FileEffectsApp.upload, FileEffectsApp.sent, |r| Html.p_v(r.map(FileEffectsApp.show_op), [Engine.test_id("sent")])),
				Html.button("Send panel", [], st.update(|s| { ..s, send_panel: !s.send_panel })),
				Engine.when(
					v.map(|s| s.send_panel),
					|| Engine.element(
						"section",
						[Html.aria_label("send panel")],
						[
							Engine.watch(
								v.map(|s| FileEffectsApp.pick_first(s.files, FileEffectsApp.whole)),
								|p| match p {
									Run(f) => [FileEffectsApp.upload(f)]
									Skip => []
								},
								st.on_result(|s, _, res| { ..s, panel_sent: FileEffectsApp.sent(res) }),
							),
						],
					),
					|| Engine.text(""),
				),
				Html.p_v(v.map(|s| s.panel_sent), [Engine.test_id("panel-sent")]),
				Html.button("Digest", [], st.update(|s| { ..s, digest: FileEffectsApp.pick_first(s.files, FileEffectsApp.whole) })),
				Html.button("Digest tail", [], st.update(|s| { ..s, digest: FileEffectsApp.pick_first(s.files, FileEffectsApp.tail_of) })),
				FileEffectsApp.operation(v.map(|s| s.digest), |f| f.sha256(), FileEffectsApp.digested, |r| Html.p_v(r.map(FileEffectsApp.show_op), [Engine.test_id("digest")])),
				Html.button("Show", [], st.update(|s| { ..s, show: FileEffectsApp.pick_first(s.files, FileEffectsApp.whole) })),
				Html.button("Hide", [], st.update(|s| { ..s, show: Skip })),
				FileEffectsApp.operation(
					v.map(|s| s.show),
					|f| f.object_url(),
					FileEffectsApp.shown_url,
					|r| Html.div(
						"preview",
						[
							Html.p_v(r.map(FileEffectsApp.url_state), [Engine.test_id("shown")]),
							Engine.element("a", [Engine.attr_v("href", r.map(FileEffectsApp.url_of)), Engine.test_id("preview")], [Engine.text("preview")]),
						],
					),
				),
			],
		)
	}

	program : Engine.Program
	program = Engine.program(|| Engine.state({ files: [], read: Skip, panel: Bool.False, send: Skip, send_panel: Bool.False, panel_sent: "nothing sent", digest: Skip, show: Skip }, |st| FileEffectsApp.view(st)))
}
