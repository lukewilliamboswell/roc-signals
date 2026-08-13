app [main] { pf: platform "../../platform/main.roc" }

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html

main : () -> Elem
main = || Html.text_s(Browser.location().map(|location| location.path))
