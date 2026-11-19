app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import DescriptionApp

main : Engine.Program
main = DescriptionApp.program

mounted : U64
mounted = Engine.mounts(main)
