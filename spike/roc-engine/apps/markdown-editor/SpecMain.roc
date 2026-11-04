import Engine
import MdApp

## The program the native spec runner drives: the same `main` as
## wasm-main.roc. Interim (Phase 2a): the native build copies this directory
## flat beside Engine.roc; Phase 2b replaces it with main-test.roc.
SpecMain := [].{
	main : Engine.Program(Engine.App)
	main = Engine.program(|| MdApp.main({}))
}
