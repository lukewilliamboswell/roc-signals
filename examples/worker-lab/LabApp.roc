import pf.Engine
import LabPage
import Picture

## Worker Lab's program: the page (`LabPage`) with the picture's tasks
## (`Picture`), which build files in their jobs.
LabApp := [].{

	program : Engine.Program
	program = LabPage.program({ strip: Picture.strip, compose: Picture.compose })
}
