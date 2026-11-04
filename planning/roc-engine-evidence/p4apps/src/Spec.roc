import Engine
import Dom

## Replays the original example's `.scm` semantic specs (converted to Roc data
## by tools/scm2roc.py) against an app on the p4 engine. Events go in through
## `Engine.event`; every assertion reads the DOM decoded from the command
## stream by `Dom` (an independent decoder), never engine state.
##
## Locators follow src/sim_dom.zig: `label` is aria-label, `test-id` is
## data-testid, `role` is the implicit role (button, h1-h6 heading, section
## region, a link) or an explicit `role` attribute, matched with the accessible
## name (aria-label, else text content), and `text` matches a text node.
Spec := [].{
	Loc : [Label(Str), TestId(Str), Role(Str, Str), Text(Str)]

	Step : [
		Click(Loc),
		Fill(Loc, Str),
		Check(Loc, Bool),
		Choose(Loc, Str),
		ExpText(Loc, Str),
		ExpValue(Loc, Str),
		ExpChecked(Loc, Bool),
		ExpVisible(Loc),
		ExpAbsent(Loc),
		ExpAttr(Loc, Str, Str),
		ExpNoAttr(Loc, Str),
		ExpDisabled(Loc, Bool),
		Mark,
	]

	S : { eng : Engine.App, dom : Dom.Model, steps : U64 }

	start : Engine.Elem(Engine.Root) -> S
	start = |view| {
		(a, c) = Engine.take_cmds(Engine.mount(view), [])
		{ eng: a, dom: Dom.apply(Dom.new({}), c), steps: 0 }
	}

	implicit_role : Dom.DNode -> Str
	implicit_role = |n| {
		explicit = Dom.attr_of(n, "role")
		if explicit != "" {
			explicit
		} else if n.tag == "button" {
			"button"
		} else if n.tag == "a" {
			"link"
		} else if n.tag == "section" {
			"region"
		} else if n.tag == "form" {
			"form"
		} else if n.tag == "h1" or n.tag == "h2" or n.tag == "h3" or n.tag == "h4" or n.tag == "h5" or n.tag == "h6" {
			"heading"
		} else {
			""
		}
	}

	name_of : Dom.Model, Dom.DNode -> Str
	name_of = |dom, n| {
		l = Dom.attr_of(n, "aria-label")
		if l != "" l else Str.join_with(n.kids.map(|k| Dom.text_of(dom, k)), "")
	}

	matches : Dom.Model, Dom.DNode, Loc -> Bool
	matches = |dom, n, loc| match loc {
		Label(x) => n.tag != "" and Dom.attr_of(n, "aria-label") == x
		TestId(x) => n.tag != "" and Dom.attr_of(n, "data-testid") == x
		Role(r, x) => n.tag != "" and Spec.implicit_role(n) == r and Spec.name_of(dom, n) == x
		Text(x) => n.tag == "" and n.text == x
	}

	find : Dom.Model, Loc -> Try(U64, [NotFound])
	find = |dom, loc| Dom.find(dom, dom.root, |n| Spec.matches(dom, n, loc))

	show_loc : Loc -> Str
	show_loc = |loc| match loc {
		Label(x) => "(label \"${x}\")"
		TestId(x) => "(test-id \"${x}\")"
		Role(r, x) => "(role ${r} :name \"${x}\")"
		Text(x) => "(text \"${x}\")"
	}

	## Dispatch event `ev` with `payload` on node index i; apply the commands.
	fire : S, U64, Str, Str -> Try(S, Str)
	fire = |{ eng, dom, steps }, i, ev, payload| {
		match Dom.target(dom, i, ev) {
			Err(_) => Err("no ${ev} handler")
			Ok((node, h)) => {
				(a, c) = Engine.take_cmds(Engine.event(eng, node, h, payload), [])
				Ok({ eng: a, dom: Dom.apply(dom, c), steps: steps + 1 })
			}
		}
	}

	set_attr : S, U64, Str, Str -> S
	set_attr = |{ eng, dom, steps }, i, name, v| { eng, dom: Dom.set_attr_on(dom, i, name, v), steps }

	bool_str : Bool -> Str
	bool_str = |b| if b "true" else "false"

	one : S, Step -> Try(S, Str)
	one = |s, step| {
		dom = s.dom
		need = |loc| Spec.find(dom, loc).map_err(|_| "no element ${Spec.show_loc(loc)}")
		match step {
			Click(loc) => {
				i = need(loc)?
				# A browser delivers no click to a disabled control.
				if Dom.attr_of(Dom.node(dom, i), "disabled") == "true" Ok(s) else Spec.fire(s, i, "click", "")
			}
			Fill(loc, v) => {
				i = need(loc)?
				Spec.fire(Spec.set_attr(s, i, "value", v), i, "input", v)
			}
			Check(loc, b) => {
				i = need(loc)?
				if (Dom.attr_of(Dom.node(dom, i), "checked") == "true") == b {
					Ok(s)
				} else {
					Spec.fire(Spec.set_attr(s, i, "checked", Spec.bool_str(b)), i, "change", Spec.bool_str(b))
				}
			}
			Choose(loc, v) => {
				i = need(loc)?
				Spec.fire(Spec.set_attr(s, i, "value", v), i, "change", v)
			}
			ExpText(loc, want) => {
				i = need(loc)?
				got = Dom.text_of(dom, i)
				if got == want Ok(s) else Err("${Spec.show_loc(loc)} text \"${got}\", expected \"${want}\"")
			}
			ExpValue(loc, want) => {
				i = need(loc)?
				got = Dom.attr_of(Dom.node(dom, i), "value")
				if got == want Ok(s) else Err("${Spec.show_loc(loc)} value \"${got}\", expected \"${want}\"")
			}
			ExpChecked(loc, want) => {
				i = need(loc)?
				got = Dom.attr_of(Dom.node(dom, i), "checked") == "true"
				if got == want Ok(s) else Err("${Spec.show_loc(loc)} checked ${Spec.bool_str(got)}")
			}
			ExpDisabled(loc, want) => {
				i = need(loc)?
				got = Dom.attr_of(Dom.node(dom, i), "disabled") == "true"
				if got == want Ok(s) else Err("${Spec.show_loc(loc)} disabled ${Spec.bool_str(got)}")
			}
			ExpVisible(loc) => {
				_ = need(loc)?
				Ok(s)
			}
			ExpAbsent(loc) => {
				match Spec.find(dom, loc) {
					Ok(_) => Err("${Spec.show_loc(loc)} is present")
					Err(_) => Ok(s)
				}
			}
			ExpAttr(loc, name, want) => {
				i = need(loc)?
				got = Dom.attr_of(Dom.node(dom, i), name)
				ctx = Dom.render(dom, Dom.node(dom, Dom.node(dom, i).parent - 1).parent - 1)
				if got == want Ok(s) else Err("${Spec.show_loc(loc)} ${name}=\"${got}\", expected \"${want}\" in ${ctx}")
			}
			ExpNoAttr(loc, name) => {
				i = need(loc)?
				got = Dom.attr_of(Dom.node(dom, i), name)
				if got == "" Ok(s) else Err("${Spec.show_loc(loc)} has ${name}=\"${got}\"")
			}
			Mark => Ok(s)
		}
	}

	## Replay one spec from a fresh mount. Err names the failing step.
	run : Engine.Elem(Engine.Root), List(Step) -> Try(S, Str)
	run = |view, steps| {
		var $s = Spec.start(view)
		var $i = 0.U64
		for st in steps {
			match Spec.one($s, st) {
				Ok(s2) => {
					$s = s2
				}
				Err(msg) => {
					return Err("step ${$i.to_str()}: ${msg}")
				}
			}
			$i = $i + 1
		}
		Ok($s)
	}
}
