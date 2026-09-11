import http.Method
import http.Request exposing [Request]
import http.Response exposing [Response]

## Native HTTP requests as effectful functions, called from an action's
## effect. Requests and responses are the `roc-lang/http` package's values, so
## packages built on those types work unchanged. Each call runs to completion
## on the effect's worker; bodies are bounded at 8 MiB in each direction.
Http := [].{
	Error := [
		InvalidRequest(Str),
		Network(Str),
		Timeout,
		TooLarge(Str),
		Status(U16),
		InvalidUtf8,
		Unavailable(Str),
	].{
		is_eq : _
	}

	## Send a request and wait for its response. Redirects are followed; a
	## response with any status is a success, and `NoTimeout` waits as long as
	## the server does.
	send! : Request => Try(Response, Error)

	## `GET` a URL with a 30 second timeout.
	get! : Str => Try(Response, Error)
	get! = |uri| Http.send!(Request.from_method(Method.GET).with_uri(uri).with_timeout(TimeoutMilliseconds(30000)))

	## `GET` a URL and return a successful response body as text; a status
	## outside 200-299 is `Status`, and a body that is not UTF-8 is `InvalidUtf8`.
	get_text! : Str => Try(Str, Error)
	get_text! = |uri| match get!(uri) {
		Err(error) => Err(error)
		Ok(response) => {
			status = Response.status(response)
			if status >= 200 and status < 300 {
				match Str.from_utf8(Response.body(response)) {
					Ok(text) => Ok(text)
					Err(_) => Err(InvalidUtf8)
				}
			} else {
				Err(Status(status))
			}
		}
	}

	## Describe a failure without losing its typed case.
	error_text : Error -> Str
	error_text = |error| match error {
		InvalidRequest(detail) => "Invalid request: ${detail}"
		Network(detail) => "Network error: ${detail}"
		Timeout => "The request timed out"
		TooLarge(detail) => "Too large: ${detail}"
		Status(status) => "HTTP status ${status.to_str()}"
		InvalidUtf8 => "The response body is not valid UTF-8"
		Unavailable(detail) => "Native service unavailable: ${detail}"
	}
}
