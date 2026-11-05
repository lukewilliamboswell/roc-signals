app [Instance, main] {
	pf: platform "../../platform/main.roc",
	plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.5.0/UstpTQVssohnU8U6Q5WpwfGxKuYZF8uWzjddwKMbTcp.tar.zst",
}

import pf.Engine
import StatusApp

## Status Page, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = StatusApp.program
