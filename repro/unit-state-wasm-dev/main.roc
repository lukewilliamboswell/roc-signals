app [main] { pf: platform "../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Ui

main : () -> Elem
main = || Ui.state({}, |_state| Html.text("Unit state"))
