//! The hosted `Http` function: one request performed to completion on the
//! calling effect worker, with the same `http1` byte framing the Roc side
//! encodes and decodes.
use std::time::Duration;

const MAX_BODY: usize = 8 * 1024 * 1024;
const MAX_PACKET: usize = MAX_BODY + 64 * 1024;

struct Request {
    method: String,
    uri: String,
    timeout: Option<Duration>,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

enum HttpError {
    InvalidRequest(String),
    Network(String),
    Timeout,
    TooLarge(String),
    Unavailable(String),
}

struct Reader<'a>(&'a [u8]);
impl<'a> Reader<'a> {
    fn frame(&mut self) -> Result<&'a [u8], &'static str> {
        let colon = self.0.iter().position(|b| *b == b':').ok_or("missing length")?;
        let length_text = std::str::from_utf8(&self.0[..colon]).map_err(|_| "invalid length")?;
        let length: usize = length_text.parse().map_err(|_| "invalid length")?;
        if length.to_string() != length_text {
            return Err("noncanonical length");
        }
        let rest = &self.0[colon + 1..];
        let value = rest.get(..length).ok_or("truncated frame")?;
        self.0 = &rest[length..];
        Ok(value)
    }
    fn text(&mut self) -> Result<&'a str, &'static str> {
        std::str::from_utf8(self.frame()?).map_err(|_| "frame is not UTF-8")
    }
    fn number(&mut self) -> Result<u64, &'static str> {
        let text = self.text()?;
        let value: u64 = text.parse().map_err(|_| "invalid number")?;
        if value.to_string() != text {
            return Err("noncanonical number");
        }
        Ok(value)
    }
}

fn decode(packet: &[u8]) -> Result<Request, &'static str> {
    if packet.len() > MAX_PACKET {
        return Err("packet limit");
    }
    let mut reader = Reader(packet);
    if reader.text()? != "http1" {
        return Err("unsupported codec");
    }
    let method = reader.text()?.to_owned();
    let uri = reader.text()?.to_owned();
    let timeout = match reader.text()? {
        "none" => None,
        text => {
            let ms: u64 = text.parse().map_err(|_| "invalid timeout")?;
            Some(Duration::from_millis(ms))
        }
    };
    let count = reader.number()? as usize;
    if count > 256 {
        return Err("too many headers");
    }
    let mut headers = Vec::with_capacity(count);
    for _ in 0..count {
        let name = reader.text()?.to_owned();
        let value = reader.text()?.to_owned();
        headers.push((name, value));
    }
    let body = reader.frame()?.to_vec();
    if !reader.0.is_empty() {
        return Err("trailing fields");
    }
    Ok(Request {
        method,
        uri,
        timeout,
        headers,
        body,
    })
}

fn append_frame(output: &mut Vec<u8>, value: &[u8]) {
    output.extend_from_slice(format!("{}:", value.len()).as_bytes());
    output.extend_from_slice(value);
}

fn encode(result: Result<(u16, Vec<(String, String)>, Vec<u8>), HttpError>) -> (bool, Vec<u8>) {
    let mut packet = Vec::new();
    append_frame(&mut packet, b"http1");
    match result {
        Ok((status, headers, body)) => {
            append_frame(&mut packet, status.to_string().as_bytes());
            append_frame(&mut packet, headers.len().to_string().as_bytes());
            for (name, value) in headers {
                append_frame(&mut packet, name.as_bytes());
                append_frame(&mut packet, value.as_bytes());
            }
            append_frame(&mut packet, &body);
            (false, packet)
        }
        Err(error) => {
            let (code, detail) = match error {
                HttpError::InvalidRequest(detail) => ("invalid-request", detail),
                HttpError::Network(detail) => ("network", detail),
                HttpError::Timeout => ("timeout", String::new()),
                HttpError::TooLarge(detail) => ("too-large", detail),
                HttpError::Unavailable(detail) => ("unavailable", detail),
            };
            append_frame(&mut packet, code.as_bytes());
            append_frame(&mut packet, bounded(detail).as_bytes());
            (true, packet)
        }
    }
}

/// Diagnostic detail is bounded like the Files errors, on a character boundary.
fn bounded(detail: String) -> String {
    const LIMIT: usize = 4096 - " [truncated]".len();
    if detail.len() <= 4096 {
        return detail;
    }
    let mut end = LIMIT;
    while !detail.is_char_boundary(end) {
        end -= 1;
    }
    format!("{} [truncated]", &detail[..end])
}

fn classify(error: reqwest::Error) -> HttpError {
    if error.is_timeout() {
        HttpError::Timeout
    } else if error.is_builder() {
        HttpError::InvalidRequest(error.to_string())
    } else {
        HttpError::Network(error.to_string())
    }
}

async fn perform(request: Request) -> Result<(u16, Vec<(String, String)>, Vec<u8>), HttpError> {
    let method = reqwest::Method::from_bytes(request.method.as_bytes())
        .map_err(|_| HttpError::InvalidRequest(format!("unsupported method {}", request.method)))?;
    let url = reqwest::Url::parse(&request.uri)
        .map_err(|error| HttpError::InvalidRequest(format!("{}: {error}", request.uri)))?;
    let client = reqwest::Client::builder().build().map_err(classify)?;
    let mut builder = client.request(method, url);
    for (name, value) in &request.headers {
        builder = builder.header(name, value);
    }
    if let Some(timeout) = request.timeout {
        builder = builder.timeout(timeout);
    }
    let mut response = builder.body(request.body).send().await.map_err(classify)?;
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| (name.as_str().to_owned(), String::from_utf8_lossy(value.as_bytes()).into_owned()))
        .collect();
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(classify)? {
        if body.len() + chunk.len() > MAX_BODY {
            return Err(HttpError::TooLarge(format!("response body exceeds {MAX_BODY} bytes")));
        }
        body.extend_from_slice(&chunk);
    }
    Ok((status, headers, body))
}

fn run(packet: &[u8]) -> (bool, Vec<u8>) {
    let request = match decode(packet) {
        Ok(request) => request,
        Err(reason) => return encode(Err(HttpError::InvalidRequest(format!("malformed Http request: {reason}")))),
    };
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => return encode(Err(HttpError::Unavailable(format!("no async runtime: {error}")))),
    };
    encode(runtime.block_on(perform(request)))
}

/// Performs one HTTP request for the Zig host's hosted `Http` function. The
/// result packet is written to a buffer the caller returns through
/// `signals_http_release`; the return value is 1 when it is an error packet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_http_run(
    request_ptr: *const u8,
    request_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> u32 {
    let request = unsafe { std::slice::from_raw_parts(request_ptr, request_len) };
    let (failed, payload) = run(request);
    let mut bytes = payload.into_boxed_slice();
    unsafe {
        *out_len = bytes.len();
        *out_ptr = bytes.as_mut_ptr();
    }
    std::mem::forget(bytes);
    u32::from(failed)
}

/// Frees a packet buffer returned by `signals_http_run`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_http_release(ptr: *mut u8, len: usize) {
    if len == 0 {
        return;
    }
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_round_trip_through_the_frame_codec() {
        let mut packet = Vec::new();
        for field in ["http1", "POST", "https://example.test/x", "1500", "1", "accept", "text/plain"] {
            append_frame(&mut packet, field.as_bytes());
        }
        append_frame(&mut packet, b"body \xff");
        let request = decode(&packet).unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(request.timeout, Some(Duration::from_millis(1500)));
        assert_eq!(request.headers, vec![("accept".to_owned(), "text/plain".to_owned())]);
        assert_eq!(request.body, b"body \xff");
        assert!(decode(b"5:http13:GET").is_err());
        let (failed, error) = encode(Err(HttpError::Timeout));
        assert!(failed);
        assert_eq!(error, b"5:http17:timeout0:");
    }
}
