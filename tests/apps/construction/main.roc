app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import pf.Url
import ConstructionApp

## Boot chooses a focused contract; the legal initial frame remains ordinary UI.
main : Engine.Program
main = Engine.program_boot({}, |boot| ConstructionApp.view(mode_from_url(boot.url)))

## Construction tests hold no shared store.
Store : {}

## The default route is a legal first page.
mounted : U64
mounted = Engine.mounts(main)


## Browser boot may include the origin; mode selection uses only decoded path
## segments, with no invented base or query/fragment-dependent test behavior.
mode_from_url : Str -> Str
mode_from_url = |text| {
	url = Url.parse(text) ?? crash "contract: construction fixture requires an HTTP(S) or root-relative URL"
	"/${Str.join_with(url.path_segments(), "/")}"
}

## Actual browser origins and native relative locations select the same mode.
expect mode_from_url("http://127.0.0.1:3000/branch?mode=other#ignored") == "/branch"

## The kept-row text case is selected from its path, independently of origin.
expect mode_from_url("/row-text?source=native#ignored") == "/row-text"

## The root stays the legal default for a URL with only query and hash data.
expect mode_from_url("https://example.test/?mode=branch#branch") == "/"
