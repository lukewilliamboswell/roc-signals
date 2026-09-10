StyleProbe := [].{}

import StyleApi

expect StyleApi.style({ padding: 12 }) == "12,8"
expect StyleApi.style(StyleApi.Style.{}) == "0,8"
expect StyleApi.style({ gap: 0 }) == "0,0"
expect {
	padding = 16.U32
	StyleApi.style({ padding, }) == "16,8"
}
expect {
	value : StyleApi.Style
	value = { padding: 3, width: Fill }
	StyleApi.style({ ..value, gap: 5 }) == "3,5"
}
expect {
	left : StyleApi.Style
	left = { padding: 16.U32 }
	right : StyleApi.Style
	right = { padding: 16.U32, gap: 8.U32 }
	left == right
}
