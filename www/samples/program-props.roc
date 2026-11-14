app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine

# region program
## An app may accept all declared defaults by passing empty props.
main = Engine.program_boot({}, |boot| Engine.text(boot.url))
# endregion program

# region boot
## A pure test names only the boot value relevant to its decision.
expect {
	boot : Engine.Boot
	boot = { url: "/articles" }
	boot.url == "/articles" and boot.online and boot.visible
}
# endregion boot

## The instance holds this store beside its site tree.
Store : {}

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
