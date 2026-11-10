app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import pf.Html
import pf.Wire
import pf.Worker

main : Engine.Program
main =
	Engine.program(|| Html.p("Payloads", "wire"))
		.with_workers([area.registration(), warmest.registration(), checksum.registration()])

# region structural
## Records, tag unions, lists, numbers and strings cross as they are.
Shape : [Circle({ radius : F64 }), Rect({ width : F64, height : F64 })]

area : Worker.Program(List(Shape), F64)
area = Worker.program({
	name: "example.org/shapes/area",
	run: |shapes|
		shapes
			.map(
				|shape|
					match shape {
						Circle({ radius }) => 3.141592653589793 * radius * radius
						Rect({ width, height }) => width * height
					},
			)
			.sum(),
})

# endregion structural

# region nominal
## A nominal type crosses once it declares the two codec hooks. It is then
## sent as the value it wraps.
Celsius := { degrees : F64 }.{
	is_eq : _
	parser_for : _
	encoder_for : _

	## The reading in degrees.
	degrees : Celsius -> F64
	degrees = |c| c.degrees
}

warmest : Worker.Program(List(Celsius), Try(Celsius, [Empty]))
warmest = Worker.fallible({
	name: "example.org/weather/warmest",
	run: |readings|
		readings.fold(
			Err(Empty),
			|best, reading|
				match best {
					Ok(b) => if (reading.degrees() > b.degrees()) Ok(reading) else Ok(b)
					Err(Empty) => Ok(reading)
				},
		),
})

# endregion nominal

# region bytes
## Bulk bytes cross as one block when wrapped in `Wire.Bytes`.
checksum : Worker.Program(Wire.Bytes, U32)
checksum = Worker.program({
	name: "example.org/files/checksum",
	run: |bytes| Wire.Bytes.to_list(bytes).fold(0, |sum, byte| sum + byte.to_u32()),
})

## A request for a file's bytes, wrapped for sending.
check_file : List(U8) -> Engine.Req
check_file = |contents| checksum.request(Wire.Bytes.from_list(contents))

# endregion bytes
