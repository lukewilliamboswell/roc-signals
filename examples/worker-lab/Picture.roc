import pf.Engine exposing [File]
import pf.Files
import pf.Worker
import Lab

## The Worker Lab's picture tasks, which build files. A strip's job draws
## its rows and writes them as a BMP file of their own, so the page can show
## each strip as it arrives; the composing job writes one picture from every
## strip, its header followed by each strip's pixels appended by reference,
## so composing copies nothing but the header.
Picture := [].{

	## Draws one strip. A timeout the user picks is the task's, as for
	## the other workloads, so there is a task per timeout.
	strip : [Unlimited, Ms(U32)] -> Worker.Task(Lab.StripSpec, Lab.Drawn, [TooLarge])
	strip = |timeout| Worker.task({ name: Lab.strip_task, run!: Picture.strip!, timeout })

	## The strip's pixels, then its file: a header for its own size and
	## the pixels, which are its escape counts. Its hash and sum come back
	## beside the file, so the page can check the strip without reading it.
	strip! : Lab.StripSpec => Try(Lab.Drawn, [TooLarge])
	strip! = |spec| {
		pixels = Lab.strip(spec)
		out = Files.build!({ name: "strip-${(spec.index + 1).to_str()}.bmp", mime: Mime("image/bmp") })
		out.append!(Lab.bmp_header({ width: spec.width, height: spec.rows }))?
		out.append!(pixels)?
		Ok({ file: out.finish!(), hash: Lab.fnv(pixels), escapes: pixels.fold(0, |sum, b| sum + b.to_u64()) })
	}

	## Composes a drawing's strips into one picture.
	compose : Worker.Task(Lab.Composition, File, [TooLarge])
	compose = Worker.task({ name: Lab.compose_task, run!: Picture.compose! })

	## A header for the whole picture, then each strip after its own header,
	## by reference: the job reads no strip, and the picture's pixels are
	## the strips' own bytes.
	compose! : Lab.Composition => Try(File, [TooLarge])
	compose! = |{ name, width, height, strips }| {
		out = Files.build!({ name, mime: Mime("image/bmp") })
		out.append!(Lab.bmp_header({ width, height }))?
		for part in strips {
			out.append_file!(part.slice({ start: Lab.bmp_header_bytes, len: part.size() - Lab.bmp_header_bytes }))
		}
		Ok(out.finish!())
	}
}
