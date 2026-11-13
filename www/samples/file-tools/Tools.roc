import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html

## One chosen file, and four things to do with it on the page: upload it,
## digest it, preview it, and read a small one as text.
Tools := [].{

	## The chosen file, and what the user last asked to do with it.
	S : { file : [None, Chosen(File)], doing : Doing }

	## An operation on the chosen file, or nothing.
	Doing : [Nothing, Uploading(File), Digesting(File), Previewing(File), Reading(File)]

	chosen : S, Engine.Received -> S
	chosen = |s, { files, refused: _ }| match files {
		[file, ..] => { file: Chosen(file), doing: Nothing }
		[] => s
	}

	do : S, (File -> Doing) -> S
	do = |s, make| match s.file {
		Chosen(file) => { ..s, doing: make(file) }
		None => s
	}

	# region requests
	## The request for what the user asked. Upload, digest and preview act on
	## the file where the browser keeps it; only `read_utf8` brings its bytes
	## into the page.
	plan : Doing -> List(Engine.Request)
	plan = |doing| match doing {
		Uploading(file) => [file.upload({ url: "/files/${file.name()}", method: "PUT", headers: [("content-type", file.mime())], timeout: Ms(60000) })]
		Digesting(file) => [file.sha256()]
		Previewing(file) => [file.object_url()]
		Reading(file) => [file.read_utf8({})]
		Nothing => []
	}
	# endregion requests

	# region answers
	## What the page shows for an answer. A preview keeps the file beside its
	## URL: the URL works while some value holds the file.
	Shown : [Idle, Busy, Uploaded(Str), Digest(Str), Preview(File, Str), Text(Str), Failed(Str)]

	answer : Doing, Engine.Result -> Shown
	answer = |doing, res| match doing {
		Uploading(_) =>
			match Engine.http_text(res) {
				Ok(body) => Uploaded(body)
				Err(e) => Failed("The upload failed: ${Str.inspect(e)}")
			}
		Digesting(_) =>
			match Engine.file_digest(res) {
				Ok(bytes) => Digest(Tools.hex(bytes))
				Err(e) => Failed("No digest: ${Str.inspect(e)}")
			}
		Previewing(file) =>
			match Engine.file_url(res) {
				Ok(url) => Preview(file, url)
				Err(e) => Failed("No preview: ${Str.inspect(e)}")
			}
		Reading(_) =>
			match Engine.file_text(res) {
				Ok(text) => Text(text)
				Err(TooLarge) => Failed("The file is too large to read on the page.")
				Err(InvalidUtf8) => Failed("The file is not text.")
				Err(e) => Failed("The file could not be read: ${Str.inspect(e)}")
			}
		Nothing => Idle
	}
	# endregion answers

	hex : List(U8) -> Str
	hex = |bytes| {
		digits = "0123456789abcdef".to_utf8()
		var $out = []
		for b in bytes {
			$out = $out.append(digits.get(b.shr_zf_wrap(4).to_u64()) ?? 48).append(digits.get(b.bitwise_and(15).to_u64()) ?? 48)
		}
		Str.from_utf8($out) ?? ""
	}

	describe : Shown -> Str
	describe = |shown| match shown {
		Idle => "Choose a file."
		Busy => "Working…"
		Uploaded(body) => "Uploaded: ${body}"
		Digest(digits) => "SHA-256 ${digits}"
		Preview(file, _) => "Previewing ${file.name()}"
		Text(text) => text
		Failed(message) => message
	}

	preview_src : Shown -> [Absent, Present(Str)]
	preview_src = |shown| match shown {
		Preview(_, url) => Present(url)
		_ => Absent
	}

	view : State(In(Root, S), S) -> Elem(In(Root, S))
	view = |st| {
		v = st.signal()
		Html.div(
			"tools",
			[
				Html.file_input(Engine.const("File"), {}, st.set_value(Tools.chosen)),
				Html.button("Upload", [], st.update(|s| Tools.do(s, |f| Uploading(f)))),
				Html.button("Digest", [], st.update(|s| Tools.do(s, |f| Digesting(f)))),
				Html.button("Preview", [], st.update(|s| Tools.do(s, |f| Previewing(f)))),
				Html.button("Read", [], st.update(|s| Tools.do(s, |f| Reading(f)))),
				Engine.resource(
					v.map(|s| s.doing),
					{
						init: Idle,
						pending: |_, doing| if (doing == Nothing) Idle else Busy,
						plan: Tools.plan,
						resolve: |_, doing, res| Tools.answer(doing, res),
					},
					|shown| Html.div(
						"result",
						[
							Html.p_s(shown.map(Tools.describe), [Engine.test_id("result")]),
							Engine.element("img", [Engine.attr_presence("src", shown.map(Tools.preview_src)), Engine.attr("alt", "")], []),
						],
					),
				),
			],
		)
	}

	program : Engine.Program
	program = Engine.program(|| Engine.state({ file: None, doing: Nothing }, Tools.view))
}
