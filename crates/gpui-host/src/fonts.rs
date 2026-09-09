//! Embedded font registration. Apps declare fonts as protocol data (the
//! `native_fonts` scalar, text field 15): a newline-delimited v1 record with a
//! family line and a standard-base64 data line per font. The engine validates
//! the record before publication; this module re-validates defensively, decodes
//! the payload, and registers each font with the GPUI text system exactly once.
//! Bound violations are visible host errors, never panics.

use std::borrow::Cow;
use std::collections::HashMap;

/// Host-enforced bounds, shared with the Zig engine's validator.
pub const MAX_FONTS: usize = 8;
pub const MAX_FONT_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_FONT_FAMILY_BYTES: usize = 128;

pub struct ParsedFont {
    pub family: String,
    pub bytes: Vec<u8>,
}

/// Parses and bounds-checks a complete v1 declaration.
pub fn parse_declaration(declaration: &str) -> Result<Vec<ParsedFont>, String> {
    let mut lines = declaration.split('\n');
    if lines.next() != Some("1") {
        return Err("embedded font declaration has an unknown version".into());
    }
    let mut fonts = Vec::new();
    while let Some(family) = lines.next() {
        let Some(data) = lines.next() else {
            return Err(format!("embedded font '{family}' is missing its data line"));
        };
        if family.is_empty() || family.len() > MAX_FONT_FAMILY_BYTES {
            return Err("embedded font family name must be 1 to 128 bytes".into());
        }
        if fonts.len() == MAX_FONTS {
            return Err(format!("an app registers at most {MAX_FONTS} embedded fonts"));
        }
        let bytes = decode_base64(data)
            .ok_or_else(|| format!("embedded font '{family}' carries invalid base64 data"))?;
        if bytes.is_empty() || bytes.len() > MAX_FONT_BYTES {
            return Err(format!(
                "embedded font '{family}' must decode to 1 to {MAX_FONT_BYTES} bytes"
            ));
        }
        fonts.push(ParsedFont {
            family: family.to_owned(),
            bytes,
        });
    }
    if fonts.is_empty() {
        return Err("embedded font declaration lists no fonts".into());
    }
    Ok(fonts)
}

/// Decodes standard base64 with `=` padding. Returns None on any malformation.
fn decode_base64(data: &str) -> Option<Vec<u8>> {
    let data = data.as_bytes();
    if data.is_empty() || data.len() % 4 != 0 {
        return None;
    }
    let value = |byte: u8| -> Option<u32> {
        match byte {
            b'A'..=b'Z' => Some(u32::from(byte - b'A')),
            b'a'..=b'z' => Some(u32::from(byte - b'a') + 26),
            b'0'..=b'9' => Some(u32::from(byte - b'0') + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let padding = data.iter().rev().take(2).filter(|&&b| b == b'=').count();
    let body = &data[..data.len() - padding];
    if body.iter().any(|&b| b == b'=') {
        return None;
    }
    let mut out = Vec::with_capacity(data.len() / 4 * 3);
    for chunk in data.chunks_exact(4) {
        let quantum = chunk.iter().take_while(|&&b| b != b'=').count();
        if quantum < 2 {
            return None;
        }
        let mut accumulator: u32 = 0;
        for &byte in &chunk[..quantum] {
            accumulator = (accumulator << 6) | value(byte)?;
        }
        accumulator <<= 6 * (4 - quantum as u32);
        let emitted = quantum - 1;
        for index in 0..emitted {
            out.push(((accumulator >> (16 - 8 * index)) & 0xff) as u8);
        }
    }
    Some(out)
}

/// Startup font registry. Registration is keyed by family; identical
/// re-publication is a no-op, and a family that reappears with different data
/// is a visible host error because a text system cannot unregister fonts.
#[derive(Default)]
pub struct Registry {
    registered: HashMap<String, u64>,
    seen_declarations: Vec<u64>,
    errors: Vec<String>,
}

fn hash_bytes(bytes: &[u8]) -> u64 {
    // FNV-1a; identity pruning only, not integrity.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

impl Registry {
    /// Parses one declaration and returns the fonts that still need text-system
    /// registration. Violations are recorded and reported, never panicked.
    pub fn ingest(&mut self, declaration: &str) -> Vec<Cow<'static, [u8]>> {
        let declaration_hash = hash_bytes(declaration.as_bytes());
        if self.seen_declarations.contains(&declaration_hash) {
            return Vec::new();
        }
        let fonts = match parse_declaration(declaration) {
            Ok(fonts) => fonts,
            Err(message) => {
                self.record_error(message);
                return Vec::new();
            }
        };
        let mut pending = Vec::new();
        for font in fonts {
            let hash = hash_bytes(&font.bytes);
            match self.registered.get(&font.family) {
                Some(&existing) if existing == hash => {}
                Some(_) => self.record_error(format!(
                    "embedded font family '{}' was already registered with different data",
                    font.family
                )),
                None => {
                    self.registered.insert(font.family, hash);
                    pending.push(Cow::Owned(font.bytes));
                }
            }
        }
        self.seen_declarations.push(declaration_hash);
        pending
    }

    pub fn record_error(&mut self, message: String) {
        eprintln!("HOST ERROR: {message}");
        self.errors.push(message);
    }

    #[cfg(test)]
    pub fn registered_families(&self) -> Vec<String> {
        let mut families: Vec<String> = self.registered.keys().cloned().collect();
        families.sort();
        families
    }

    #[cfg(test)]
    pub fn errors(&self) -> &[String] {
        &self.errors
    }
}

/// Encodes standard base64; used by tests to build declarations.
#[cfg(test)]
pub fn encode_base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let mut accumulator: u32 = 0;
        for (index, &byte) in chunk.iter().enumerate() {
            accumulator |= u32::from(byte) << (16 - 8 * index);
        }
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(TABLE[((accumulator >> (18 - 6 * index)) & 0x3f) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn declaration(fonts: &[(&str, &[u8])]) -> String {
        let mut declaration = String::from("1");
        for (family, bytes) in fonts {
            declaration.push('\n');
            declaration.push_str(family);
            declaration.push('\n');
            declaration.push_str(&encode_base64(bytes));
        }
        declaration
    }

    #[test]
    fn base64_round_trips_every_padding_length() {
        for bytes in [&b"a"[..], b"ab", b"abc", b"abcd", b"\x00\xff\x7f"] {
            assert_eq!(decode_base64(&encode_base64(bytes)).unwrap(), bytes);
        }
        for invalid in ["AAA", "A?AA", "====", "AB=A", ""] {
            assert!(decode_base64(invalid).is_none(), "{invalid:?}");
        }
    }

    #[test]
    fn a_ninth_font_is_rejected_with_a_visible_error() {
        let fonts: Vec<(String, Vec<u8>)> = (0..9)
            .map(|index| (format!("Family {index}"), vec![index as u8; 4]))
            .collect();
        let borrowed: Vec<(&str, &[u8])> = fonts
            .iter()
            .map(|(family, bytes)| (family.as_str(), bytes.as_slice()))
            .collect();
        let mut registry = Registry::default();
        assert!(registry.ingest(&declaration(&borrowed)).is_empty());
        assert_eq!(registry.errors().len(), 1);
        assert!(registry.errors()[0].contains("at most 8"));
        assert!(registry.registered_families().is_empty());
        // Exactly eight fonts pass the bound.
        let mut registry = Registry::default();
        assert_eq!(registry.ingest(&declaration(&borrowed[..8])).len(), 8);
        assert!(registry.errors().is_empty());
    }

    #[test]
    fn an_oversized_font_is_rejected_with_a_visible_error() {
        let oversized = vec![0u8; MAX_FONT_BYTES + 1];
        let mut registry = Registry::default();
        assert!(
            registry
                .ingest(&declaration(&[("Big", oversized.as_slice())]))
                .is_empty()
        );
        assert_eq!(registry.errors().len(), 1);
        assert!(registry.errors()[0].contains("8388608"));
        let at_bound = vec![0u8; MAX_FONT_BYTES];
        let mut registry = Registry::default();
        assert_eq!(
            registry
                .ingest(&declaration(&[("Exact", at_bound.as_slice())]))
                .len(),
            1
        );
        assert!(registry.errors().is_empty());
    }

    #[test]
    fn identical_republication_never_re_registers() {
        let record = declaration(&[("Mono", b"font-bytes")]);
        let mut registry = Registry::default();
        assert_eq!(registry.ingest(&record).len(), 1);
        assert!(registry.ingest(&record).is_empty());
        assert!(registry.errors().is_empty());
        assert_eq!(registry.registered_families(), vec!["Mono".to_owned()]);
        // The same family with different data is refused visibly.
        assert!(
            registry
                .ingest(&declaration(&[("Mono", b"other-bytes")]))
                .is_empty()
        );
        assert_eq!(registry.errors().len(), 1);
        assert!(registry.errors()[0].contains("different data"));
    }

    #[test]
    fn malformed_declarations_are_visible_errors() {
        for declaration in ["", "2\nMono\nAAAA", "1", "1\nMono", "1\n\nAAAA", "1\nMono\nA?AA"] {
            let mut registry = Registry::default();
            assert!(registry.ingest(declaration).is_empty());
            assert_eq!(registry.errors().len(), 1, "{declaration:?}");
        }
    }
}
