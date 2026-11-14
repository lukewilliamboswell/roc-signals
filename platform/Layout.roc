## Plain browser layout facts. They arrive through typed handlers and keep
## geometry in CSS pixels rather than exposing browser objects or engine ids.
Layout := [].{

	## Rounded offsets from the scroller's start edges, clamped at zero.
	Scroll : { top : U32, left : U32 }

	## The observed content box in rounded CSS pixels.
	Size : { width : U32, height : U32 }

	## Intersection with the viewport (or the ahead observation's margins).
	## The ratio is in thousandths, from zero through one thousand.
	Seen : { intersecting : Bool, ratio_permille : U16 }
}
