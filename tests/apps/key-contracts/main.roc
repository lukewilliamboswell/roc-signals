app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import pf.Html
import pf.Port
import pf.Web

## The declaration and request contracts of the platform, one case per
## first page, chosen by the path the instance boots at: `/document-bound`
## mounts only that case's view, so a spec (`(setup (initial-location
## "/document-bound"))`) or a page at that path checks exactly one contract,
## and every case runs through the one native runner and the one Wasm
## build. `Checks.key_contracts!` holds each case's expected rule; the root
## path mounts a page that breaks none. Each view is the whole program of
## the fixture it replaced (tests/key-contracts/), unchanged.
main : Engine.Program
main = Engine.program_store({}, |_| store, |boot| case(boot.url))

## Every case shares the one store the table case reads; the others never
## read it.
store = Engine.store(App, Engine.table(Engine.Table.empty({}).insert(1.U64, 1.U64).insert(2, 2)))

Tag := [App]

## The table case's generated store storage type.
Store : Engine.Stored(Tag, Engine.Table(U64, U64))

## The view of the case at `path`: a deliberate contract mistake, or, at
## `/raw-controlled-attributes`, raw attributes that must stay ordinary.
case = |path| match path {
	"/document-bound" => Engine.state(0.I64, |count| Engine.element("div", [], List.repeat({}, 33).map(|_| Engine.element("span", [Engine.on_document_key({ keymap: Engine.const(Engine.Keymap.every) }, count.update(|n| n + 1))], []))))
	"/apply-noncontrol" => Engine.element("div", [Engine.ref("bad")], [Engine.watch(Engine.const({}), |_| [Engine.command(ApplyValue("bad"))], Engine.ignore({}))])
	"/apply-without-value" => Engine.element("input", [Engine.ref("bad")], [Engine.watch(Engine.const({}), |_| [Engine.command(ApplyValue("bad"))], Engine.ignore({}))])
	"/dialog-open" => Html.dialog("Controlled", { open: Engine.const(False), on_close: Engine.does([]) }, [Engine.attr("open", "")], [])
	"/dialog-dynamic-open" => Html.dialog("Controlled", { open: Engine.const(False), on_close: Engine.does([]) }, [Engine.attr_s("oPeN", Engine.const(""))], [])
	"/dialog-popover" => Html.dialog("Controlled", { open: Engine.const(False), on_close: Engine.does([]) }, [Engine.attr("popover", "auto")], [])
	"/dialog-dynamic-popover" => Html.dialog("Controlled", { open: Engine.const(False), on_close: Engine.does([]) }, [Engine.attr_s("pOpOvEr", Engine.const("auto"))], [])
	"/dialog-closedby" => Html.dialog("Controlled", { open: Engine.const(False), on_close: Engine.does([]) }, [Engine.attr("closedby", "any")], [])
	"/dialog-dynamic-closedby" => Html.dialog("Controlled", { open: Engine.const(False), on_close: Engine.does([]) }, [Engine.attr_s("cLoSeDbY", Engine.const("any"))], [])
	"/controlled-beforetoggle" => Html.dialog("Controlled", { open: Engine.const(False), on_close: Engine.does([]) }, [Engine.on("beforetoggle", Engine.does([]))], [])
	"/popover-beforetoggle" => Html.popover("Controlled", { open: Engine.const(False), on_toggle: Engine.does([]) }, [Engine.on("beforetoggle", Engine.does([]))], [])
	"/popover-duplicate" => Html.popover("Controlled", { open: Engine.const(False), on_toggle: Engine.does([]) }, [Engine.attr("POPOVER", "manual")], [])
	"/popover-dynamic-popover" => Html.popover("Controlled", { open: Engine.const(False), on_toggle: Engine.does([]) }, [Engine.attr_s("popover", Engine.const("manual"))], [])
	"/media-undeclared" => Engine.watch(Engine.const({}), |_| [Engine.media_changes("missing-media")], Engine.ignore({}))
	"/table-order-same" =>
		Engine.table_view(
			store.cells(),
			{
				query: Engine.const({}),
				plan: |_| { keep: |_, _| Bool.True, sort: |_, row| row, compare: |_, _| Same },
				window: Engine.const(Engine.every_row),
			},
			|_, row| Html.li([], [Engine.text_s(row.signal().map(U64.to_str))]),
		)
	"/signal-text-manual-arity" => {
		join : Iter(Engine.Signal(Engine.StoreRoot(Store), Str)) -> Engine.Signal(Engine.StoreRoot(Store), Str)
		join = Engine.Signal.from_interpolation(["before", "after"]) ?? crash "interpolation hook unexpectedly rejected text segments"
		Engine.text_s(join([].iter()))
	}
	"/keep-current-subscription" => Engine.keep_current(Engine.const({}), |_| [Engine.interval(1)], Engine.ignore({}))
	"/interval-zero" => Engine.watch(Engine.const(zero(path)), |length| [Engine.interval(length)], Engine.ignore({}))
	"/timer-overflow" => Engine.watch(Engine.const(zero(path)), |length| [Engine.timer(3000000000 + length)], Engine.ignore({}))
	"/interval-overflow" => Engine.watch(Engine.const(zero(path)), |length| [Engine.interval(2147483648 + length)], Engine.ignore({}))
	"/timer-overflow-boundary" => Engine.watch(Engine.const(zero(path)), |length| [Engine.timer(2147483648 + length)], Engine.ignore({}))
	"/timeout-zero" => {
		call : Port.Call({}, Str)
		call = Port.call({ name: "test.roc-signals/zero-timeout", timeout: Ms(zero(path)) })
		Engine.watch(Engine.const({}), |_| [call.ask({})], Engine.ignore({}))
	}
	"/raw-controlled-attributes" => Engine.element("dialog", [Engine.attr_s("open", Engine.const("")), Engine.attr("popover", "manual"), Engine.attr_s("closedby", Engine.const("any")), Engine.on("beforetoggle", Engine.does([]))], [])
	"/raw-uppercase-value" => Engine.element("input", [Engine.attr(Web.AttrName.from_str("VALUE") ?? crash "valid raw attribute", "ordinary")], [])
	_ => Engine.text("key contracts: boot at a case's path")
}

## Zero, from the boot path, so a duration the compiler could fold stays a
## value only the running instance knows, as a request's is.
zero : Str -> U32
zero = |path| {
	length = path.count_utf8_bytes().to_u32_wrap()
	length - length
}

## The root path's page breaks no contract.
mounted : U64
mounted = Engine.mounts(main)
