//! Bounded application asset resolution and integrity verification.
//!
//! Every image source is a relative path resolved against one process-wide
//! assets root: `--assets-root <dir>` if given, else `ROC_SIGNALS_ASSETS_ROOT`,
//! else `assets/` beside the executable. Absolute paths, `..` traversal, URI
//! schemes, and symbolic links never resolve; a source that fails to resolve
//! renders as a neutral placeholder instead of reaching the filesystem.
use crate::file_io::{self, FileError};
use sha2::{Digest, Sha256};
use std::{
    path::PathBuf,
    sync::{OnceLock, atomic::AtomicBool},
};

/// Complete per-asset byte bound for startup verification hashing.
pub const MAX_ASSET_BYTES: usize = 32 * 1024 * 1024;
/// Manifest entry bound shared with the Zig publication validator.
pub const MAX_MANIFEST_ASSETS: usize = 256;
/// Relative source path bound shared with the Zig publication validator.
pub const MAX_SOURCE_BYTES: usize = 1024;

static ROOT: OnceLock<PathBuf> = OnceLock::new();

/// Commits the process-wide assets root exactly once, before any resolution.
/// A relative root is anchored to the working directory and canonicalized, so
/// the no-follow verification primitives receive an absolute, link-free base;
/// symlink refusal applies to everything below the root.
pub fn set_root(path: PathBuf) {
    let absolute = if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .expect("working directory required for a relative assets root")
            .join(path)
    };
    let absolute = absolute.canonicalize().unwrap_or(absolute);
    ROOT.set(absolute).expect("assets root committed twice");
}

/// Returns the committed root, or the default `assets/` beside the executable.
pub fn root() -> PathBuf {
    ROOT.get().cloned().unwrap_or_else(|| {
        std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|dir| dir.join("assets")))
            .unwrap_or_else(|| PathBuf::from("assets"))
    })
}

/// Accepts only plain relative paths that stay inside the assets root.
/// Nothing here touches the filesystem; rejection is a rendering decision.
pub fn validate_source(source: &str) -> Result<(), &'static str> {
    if source.is_empty() {
        return Err("empty source");
    }
    if source.len() > MAX_SOURCE_BYTES {
        return Err("source exceeds 1024 UTF-8 bytes");
    }
    if source.contains('\0') {
        return Err("source contains a NUL byte");
    }
    // Rejecting every colon refuses URIs (http:, file:, data:) and Windows
    // drive prefixes with one rule; assets never need one in a file name.
    if source.contains(':') {
        return Err("URIs and drive prefixes are not asset sources");
    }
    if source.contains('\\') {
        return Err("asset sources use forward slashes");
    }
    if source.starts_with('/') {
        return Err("asset sources are relative to the assets root");
    }
    for part in source.split('/') {
        if part.is_empty() || part == "." || part == ".." {
            return Err("traversal or empty path component");
        }
    }
    Ok(())
}

/// Resolves a validated source to an existing regular file under the root.
/// Symbolic links anywhere below the root are refused, mirroring file_io.
pub fn resolve(source: &str) -> Option<PathBuf> {
    validate_source(source).ok()?;
    let mut path = root();
    for part in source.split('/') {
        path.push(part);
        if std::fs::symlink_metadata(&path).ok()?.file_type().is_symlink() {
            return None;
        }
    }
    std::fs::metadata(&path).ok()?.is_file().then_some(path)
}

/// Per-asset verification outcome; anything unreadable in place is Missing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssetStatus {
    Ok,
    Missing,
    Mismatch,
}

/// One verified manifest row: the requested name and its outcome.
pub type AssetReport = Vec<(String, AssetStatus)>;

/// Hashes every manifest entry under the assets root through the no-follow
/// file primitives. A missing, symlinked, or special file reports Missing; a
/// present file with a different SHA-256 reports Mismatch. An asset above the
/// 32 MiB bound or an unreadable file fails the whole task with its typed error.
pub fn verify(entries: &[(String, String)], cancel: &AtomicBool) -> Result<AssetReport, FileError> {
    let root = root();
    let root_text = root
        .to_str()
        .ok_or_else(|| FileError::InvalidUtf8("assets root".into()))?;
    let mut report = Vec::with_capacity(entries.len());
    for (name, expected) in entries {
        validate_source(name).map_err(|reason| {
            FileError::InvalidPath(file_io::bounded_detail(format!("{name}: {reason}")))
        })?;
        let path = format!("{root_text}/{name}");
        let status = match file_io::read_bytes(&path, cancel, MAX_ASSET_BYTES) {
            Ok(bytes) => {
                let digest = format!("{:x}", Sha256::digest(&bytes));
                if digest == *expected {
                    AssetStatus::Ok
                } else {
                    AssetStatus::Mismatch
                }
            }
            Err(FileError::NotFound(_) | FileError::InvalidPath(_)) => AssetStatus::Missing,
            Err(error) => return Err(error),
        };
        report.push((name.clone(), status));
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sources_outside_the_assets_root_never_validate() {
        for source in [
            "",
            "/etc/passwd",
            "../secret.png",
            "avatars/../../secret.png",
            "avatars/./x.png",
            "avatars//x.png",
            "https://example.com/x.png",
            "file:///tmp/x.png",
            "data:image/png;base64,AAAA",
            "C:\\assets\\x.png",
            "avatars\\x.png",
            "x\0.png",
        ] {
            assert!(validate_source(source).is_err(), "accepted {source:?}");
        }
        assert!(validate_source("avatars/maya.png").is_ok());
        assert!(validate_source("glyphs/λ.png").is_ok());
        assert!(validate_source(&"x".repeat(MAX_SOURCE_BYTES + 1)).is_err());
    }

    #[test]
    fn manifest_verification_reports_ok_missing_and_mismatch() {
        // macOS temp_dir starts with /var, a symlink to /private/var; the
        // no-follow file primitives refuse symlinked components by design.
        let dir = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("signals-assets-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("avatars")).unwrap();
        std::fs::write(dir.join("avatars/maya.png"), b"pixels").unwrap();
        set_root(dir.clone());
        let good = format!("{:x}", Sha256::digest(b"pixels"));
        let cancel = AtomicBool::new(false);
        let report = verify(
            &[
                ("avatars/maya.png".into(), good.clone()),
                ("avatars/jon.png".into(), good.clone()),
                ("avatars/maya.png".into(), "0".repeat(64)),
            ],
            &cancel,
        )
        .unwrap();
        assert_eq!(
            report,
            vec![
                ("avatars/maya.png".into(), AssetStatus::Ok),
                ("avatars/jon.png".into(), AssetStatus::Missing),
                ("avatars/maya.png".into(), AssetStatus::Mismatch),
            ]
        );
        assert!(verify(&[("../maya.png".into(), good)], &cancel).is_err());
        assert_eq!(resolve("avatars/maya.png"), Some(dir.join("avatars/maya.png")));
        assert_eq!(resolve("avatars/jon.png"), None);
        assert_eq!(resolve("../avatars/maya.png"), None);
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(dir.join("avatars/maya.png"), dir.join("avatars/link.png"))
                .unwrap();
            assert_eq!(resolve("avatars/link.png"), None);
            let linked = verify(
                &[("avatars/link.png".into(), format!("{:x}", Sha256::digest(b"pixels")))],
                &cancel,
            )
            .unwrap();
            assert_eq!(linked, vec![("avatars/link.png".into(), AssetStatus::Missing)]);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
}
