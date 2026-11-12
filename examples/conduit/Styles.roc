## Conduit's class lists, named for what they style, so its views share one
## look and say `Styles.primary_button` rather than repeat the classes.
Styles := {}.{
	shell : Str
	shell = "conduit-app flex min-h-screen flex-col text-zinc-900"

	header : Str
	header = "sticky top-0 z-20 mx-auto flex w-full max-w-6xl flex-wrap items-center justify-between gap-3 border-b border-zinc-200 bg-white px-5 py-4 sm:px-8"

	main : Str
	main = "grow"

	footer : Str
	footer = "mt-auto border-t border-zinc-950 bg-white px-5 py-6 text-center text-sm text-zinc-500 sm:px-8"

	page : Str
	page = "mx-auto w-full max-w-6xl px-5 py-10 sm:px-8 sm:py-14"

	narrow_page : Str
	narrow_page = "mx-auto w-full max-w-lg px-5 py-12 sm:px-8 sm:py-16"

	wide_page : Str
	wide_page = "mx-auto w-full max-w-3xl px-5 py-10 sm:px-8 sm:py-14"

	heading : Str
	heading = "text-4xl font-semibold tracking-normal text-zinc-950"

	subheading : Str
	subheading = "text-2xl font-semibold tracking-normal text-zinc-950"

	form : Str
	form = "grid gap-4"

	field : Str
	field = "w-full border border-zinc-950 bg-white px-4 py-3 text-base text-zinc-950 transition"

	primary_button : Str
	primary_button = "justify-self-start border border-emerald-600 bg-emerald-600 px-5 py-3 font-medium text-white transition hover:border-emerald-700 hover:bg-emerald-700"

	secondary_button : Str
	secondary_button = "border border-zinc-950 bg-white px-4 py-2 text-sm font-medium text-zinc-950 transition hover:border-emerald-500 hover:text-emerald-700"

	danger_button : Str
	danger_button = "border border-red-700 bg-white px-4 py-2 text-sm font-medium text-red-700 transition hover:bg-red-50"

	error_list : Str
	error_list = "mb-2 list-disc border border-red-600 bg-red-50 px-5 py-3 pl-10 text-sm font-medium leading-6 text-red-700"

	status_error : Str
	status_error = "border border-red-600 bg-red-50 px-4 py-3 text-sm text-red-700"

	status_success : Str
	status_success = "border border-emerald-600 bg-emerald-50 px-4 py-3 text-sm text-emerald-800"
}
