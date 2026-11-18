app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import DescriptionApp

main : Engine.Program
main = DescriptionApp.program

Store : Engine.Stored(DescriptionApp, (I64, (I64, (Bool, List(Str)))))

mounted : U64
mounted = Engine.mounts(main)
