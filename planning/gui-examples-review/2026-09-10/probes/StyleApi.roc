StyleApi := [].{
	Style := {
		padding : U32 ?? 0,
		gap : U32 ?? 8,
		width : [Auto, Fill, Px(U32)] ?? Auto,
		background : [Default, Rgb(U32)] ?? Default,
	}.{
		is_eq : _
	}

	style : Style -> Str
	style = |value| "${value.padding.to_str()},${value.gap.to_str()}"
}
