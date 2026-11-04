"""Add the app-cost region to the markdown fuzz main and derive its timing main
from the data-grid one."""
p = 'apps/markdown-editor/fuzz-main.roc'
f = open(p).read()
if 'app-parse-counts-headings' not in f:
    f = f.replace("import MdApp\n", "import MdApp\nimport Markdown\nimport Stats\nimport Outline\nimport Edit\n")
    f = f.replace('''	var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
	$s = mstep!($s, "append-word"''', '''	# The app's own work for one paragraph edit, outside the engine.
	edited = Edit.append_word(doc_of(n))
	wj = Fuzz.start_measure!("app-parse-counts-headings")
	bl = Markdown.parse(edited)
	ct = Stats.counts(edited)
	hd = Outline.headings(bl)
	_ = wj.finish!()
	_ = (ct, hd)
	var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
	$s = mstep!($s, "append-word"''')
    open(p, 'w').write(f)
s = open('apps/data-grid/timing-main.roc').read()
s = s.replace("import GridData\nimport GridApp\n", "import MdApp\n").replace("p4 data grid", "p4 markdown editor")
a = s.index("\tfor n in [1200, 12000] {")
b = s.index("\tOk({})")
s = s[:a] + '''	for n in [1, 10] {
		doc = Str.join_with(List.repeat(MdApp.sample_document, n), "\\n\\n")
		var $run = 0.U64
		while $run < 11 {
			view = MdApp.main_with(doc)
			t0 = Monotonic.now!()
			(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
			d0 = Monotonic.since(Monotonic.now!(), t0)
			_ = Stdout.line!("${n.to_str()} mount ${d0.to_nanos().to_str()}")
			var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
			$s = timed!(n, $s, "append-word", Role("button", "Append a word"), "click", "")
			$s = timed!(n, $s, "toggle-numbering", Label("Number the outline"), "change", "false")
			$s = timed!(n, $s, "reading-speed", Label("Reading speed"), "change", "300")
			$s = timed!(n, $s, "append-section", Role("button", "Append a section"), "click", "")
			_ = $s
			$run = $run + 1
		}
	}
''' + s[b:]
open('apps/markdown-editor/timing-main.roc', 'w').write(s)
