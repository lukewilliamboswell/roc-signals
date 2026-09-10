import Node

Color : [Default, Rgb(U32)]

Overflow : [Visible, Clip, Scroll]

## Native presentation types used by every control's props record. Styles are
## typed native properties, independent of CSS and semantic locators.
Gui := [].{
	## Native presentation record with defaults for every field. Use it for
	## `changes` signals: `signal.map(|value| Gui.Style.{ padding: 12 })`.
	## Zero font size and Default colors inherit from the host. Dimensions,
	## spacing and font size are logical pixels, bounded at 16384.
	Style := {
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		bg : Color ?? Default,
		hover_bg : Color ?? Default,
		active_bg : Color ?? Default,
		fg : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
	}.{
		is_eq : _
	}

	## A logical-pixel dimension. A number literal in a `Length` position is
	## pixels, written explicitly as `380.Px`; `Px(380)` is the same value.
	Length := [Auto, Fill, Px(U32)].{
		is_eq : _

		from_numeral : Numeral -> Try(Length, [InvalidNumeral(Str)])
		from_numeral = |numeral| {
			Pixels : U32
			match Pixels.from_numeral(numeral) {
				Ok(value) => Ok(Px(value))
				Err(err) => Err(err)
			}
		}
	}

	## Types a number literal as pixels: `width: 380.Px`.
	Px : Length
	Color : Color
	Overflow : Overflow

	## A command returned by an action or a state write.
	Cmd : Node.Cmd
}
