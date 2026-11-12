import Core
import Hosted

## The platform's hosted effects for a worker job, as the engine takes
## them (`Core.JobEffects`): the one place outside the platform root that
## reaches `Hosted.roc`. The platform hands this record to the engine when
## it starts a job, a preparation or a question, and to `Files.build!`;
## the files and builders made in that call carry it, so their effects are
## methods while the engine's modules stay free of hosted functions and can
## be built as a package (`main-fuzz.roc`) for the fuzz targets.
##
## Not exposed to apps. Each effect is a lambda that calls the hosted
## function, so no bare hosted function is stored as a value.
Effects := [].{

	## The job effects both hosts serve (design.md, "Workers"); each refuses
	## outside a job.
	job : Core.JobEffects
	job = {
		read!: |token, start, len| Hosted.read!(token, start, len),
		size!: |token| Hosted.size!(token),
		mint!: || Hosted.mint!(),
		open!: |token, name, mime, from, start, len| Hosted.open!(token, name, mime, from, start, len),
		append!: |token, bytes| Hosted.append!(token, bytes),
		append_file!: |token, file, start, len| Hosted.append_file!(token, file, start, len),
		finish!: |token, file| Hosted.finish!(token, file),
	}
}
