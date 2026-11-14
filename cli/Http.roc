## The little HTTP the development server speaks: which file a request asks
## for, and the bytes of a response. Only `GET` and `HEAD` of files and one
## event stream; every response closes its connection.
Http :: [].{

	## What a request asks the development server for:
	##
	## - `Page`: the app's page, with the reload script added;
	## - `Runtime(name)`: one of the platform's runtime files;
	## - `Module`: the app's development build, `app.wasm`;
	## - `Events`: the stream that tells the page to reload or shows an error;
	## - `File(path)`: one of the app's own files, by its relative path;
	## - `Refused`: a path that leaves the app's directory or names a
	##   hidden file;
	## - `Unsupported`: a method other than `GET` or `HEAD`, or no request.
	Route : [Page, Runtime(Str), Module, Events, File(Str), Refused, Unsupported]

	## The path of the event stream the reload script listens to.
	events_path = "/__signals/events"

	## Route a request line such as `GET /index.html HTTP/1.1`.
	route : Str, List(Str) -> Route
	route = |line, runtime_names|
		match line.split_on(" ") {
			[method, target, ..] if method == "GET" or method == "HEAD" => {
				path = target.split_on("?").first() ?? target
				if path == "/" or path == "/index.html" {
					Page
				} else if path == Http.events_path {
					Events
				} else if path == "/app.wasm" {
					Module
				} else {
					match decode(path.drop_prefix("/")) {
						Ok(relative) if runtime_names.contains(relative) => Runtime(relative)
						Ok(relative) if is_safe(relative) => File(relative)
						_ => Refused
					}
				}
			}
			_ => Unsupported
		}

	## A complete response that closes the connection.
	response : { status : [Found, Missing, NotAllowed], content_type : Str, body : List(U8) } -> List(U8)
	response = |{ status, content_type: body_type, body }| {
		line = match status {
			Found => "200 OK"
			Missing => "404 Not Found"
			NotAllowed => "405 Method Not Allowed"
		}
		head = "HTTP/1.1 ${line}\r\ncontent-type: ${body_type}\r\ncontent-length: ${body.len().to_str()}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n"
		head.to_utf8().concat(body)
	}

	## The head of the event stream; events follow as the app is rebuilt.
	stream_head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-store\r\nconnection: keep-alive\r\n\r\nretry: 500\n\n"

	## One server-sent event. Every line of `data` becomes a `data:` line, so
	## a multi-line compiler report arrives whole.
	event : Str, Str -> Str
	event = |name, data| {
		lines = data.split_on("\n").map(|line| "data: ${line.drop_suffix("\r")}")
		"event: ${name}\n${Str.join_with(lines, "\n")}\n\n"
	}

	## The content type a file is served with, by its name. Modules must be
	## `text/javascript`, or the browser refuses to run them.
	content_type : Str -> Str
	content_type = |path| {
		extension = path.split_on(".").last() ?? ""
		match extension {
			"html" => "text/html; charset=utf-8"
			"mjs" => "text/javascript; charset=utf-8"
			"js" => "text/javascript; charset=utf-8"
			"wasm" => "application/wasm"
			"css" => "text/css; charset=utf-8"
			"json" => "application/json"
			"map" => "application/json"
			"svg" => "image/svg+xml"
			"png" => "image/png"
			"jpg" => "image/jpeg"
			"jpeg" => "image/jpeg"
			"gif" => "image/gif"
			"webp" => "image/webp"
			"ico" => "image/x-icon"
			"txt" => "text/plain; charset=utf-8"
			"csv" => "text/csv; charset=utf-8"
			"woff2" => "font/woff2"
			_ => "application/octet-stream"
		}
	}

	## The page with `script` added as the first thing in its `<head>` (or
	## at its start), so the script runs before any of the page's own and
	## sees an error the page's first script throws.
	inject : Str, Str -> Str
	inject = |page, script|
		if page.contains("<head>") {
			page.replace_first("<head>", "<head>${script}")
		} else {
			"${script}${page}"
		}
}

## A path made of ordinary names: no empty part, no `.` or `..`, nothing
## hidden, no backslash.
is_safe : Str -> Bool
is_safe = |path|
	!path.is_empty() and !path.contains("\\") and path.split_on("/").all(|part| !part.is_empty() and !part.starts_with("."))

## Decode `%XX` escapes. A malformed escape or a result that is not UTF-8 is
## refused.
decode : Str -> Try(Str, [Malformed])
decode = |path| {
	bytes = path.to_utf8()
	var $out = []
	var $index = 0
	while $index < bytes.len() {
		byte = bytes.get($index) ?? 0
		if byte == '%' {
			high = hex_value(bytes.get($index + 1) ?? 0)?
			low = hex_value(bytes.get($index + 2) ?? 0)?
			$out = $out.append(high * 16 + low)
			$index = $index + 3
		} else {
			$out = $out.append(byte)
			$index = $index + 1
		}
	}
	Str.from_utf8($out).map_err(|_| Malformed)
}

hex_value : U8 -> Try(U8, [Malformed])
hex_value = |byte|
	if byte >= '0' and byte <= '9' {
		Ok(byte - '0')
	} else if byte >= 'a' and byte <= 'f' {
		Ok(byte - 'a' + 10)
	} else if byte >= 'A' and byte <= 'F' {
		Ok(byte - 'A' + 10)
	} else {
		Err(Malformed)
	}

## Requests are routed to the page, the runtime, the module, the event
## stream and the app's files, and nothing outside the app is served.
expect {
	runtime = ["runtime.mjs", "worker.mjs"]
	actual = [
		"GET / HTTP/1.1",
		"GET /index.html?x=1 HTTP/1.1",
		"HEAD /runtime.mjs HTTP/1.1",
		"GET /worker.mjs HTTP/1.1",
		"GET /app.wasm HTTP/1.1",
		"GET /__signals/events HTTP/1.1",
		"GET /img/my%20logo.svg HTTP/1.1",
		"GET /../secret HTTP/1.1",
		"GET /%2e%2e/secret HTTP/1.1",
		"GET /.git/config HTTP/1.1",
		"GET /a//b HTTP/1.1",
		"GET /bad%zz HTTP/1.1",
		"POST / HTTP/1.1",
		"",
	].map(|line| Http.route(line, runtime))
	expected = [Page, Page, Runtime("runtime.mjs"), Runtime("worker.mjs"), Module, Events, File("img/my logo.svg"), Refused, Refused, Refused, Refused, Refused, Unsupported, Unsupported]
	actual == expected
}

## A response states its status, type and length, and closes.
expect {
	actual = Str.from_utf8_lossy(Http.response({ status: Missing, content_type: "text/plain", body: "gone".to_utf8() }))
	actual == "HTTP/1.1 404 Not Found\r\ncontent-type: text/plain\r\ncontent-length: 4\r\ncache-control: no-store\r\nconnection: close\r\n\r\ngone"
}

## Every line of an event's data is a data line.
expect Http.event("failed", "a\r\nb") == "event: failed\ndata: a\ndata: b\n\n"

## Modules, the module and pages get the types browsers require.
expect ["runtime.mjs", "app.wasm", "index.html", "x.bin"].map(Http.content_type) == ["text/javascript; charset=utf-8", "application/wasm", "text/html; charset=utf-8", "application/octet-stream"]

## The script goes first in the head, or first in a page without one.
expect [Http.inject("<html><head><title>x</title></head>", "S"), Http.inject("<p>x", "S")] == ["<html><head>S<title>x</title></head>", "S<p>x"]
