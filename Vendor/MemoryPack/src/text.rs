//! Text handling shared by both readers: secret redaction and tag extraction.

/// Token prefixes that identify a credential regardless of surrounding text.
/// Each entry pairs the prefix with the shortest real token that uses it, so a
/// bare mention like "an sk- key" is never mistaken for the key itself.
const SECRET_PREFIXES: &[(&str, usize)] = &[
    ("sk-", 24),
    ("sk_live_", 24),
    ("sk_test_", 24),
    ("rk_live_", 24),
    ("pk_live_", 24),
    ("ghp_", 36),
    ("gho_", 36),
    ("ghu_", 36),
    ("ghs_", 36),
    ("ghr_", 36),
    ("github_pat_", 40),
    ("glpat-", 20),
    ("AKIA", 20),
    ("ASIA", 20),
    ("xoxb-", 24),
    ("xoxp-", 24),
    ("xoxa-", 24),
    ("xoxs-", 24),
    ("AIza", 35),
    ("npm_", 36),
    ("dop_v1_", 40),
    ("shpat_", 32),
    ("hf_", 30),
    ("SG.", 40),
];

const REDACTED: &str = "[redacted-secret]";
const KEY_BLOCK_START: &str = "-----BEGIN";
const KEY_BLOCK_END: &str = "PRIVATE KEY-----";

fn is_token_char(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '_' | '-' | '.')
}

fn looks_like_secret(token: &str) -> bool {
    SECRET_PREFIXES
        .iter()
        .any(|(prefix, minimum)| token.len() >= *minimum && token.starts_with(prefix))
}

/// Replaces PEM private key blocks with a single marker.
fn redact_key_blocks(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(KEY_BLOCK_START) {
        let after = &rest[start..];
        // Only a BEGIN header that actually opens a private key is a secret;
        // "-----BEGIN CERTIFICATE-----" is not.
        let Some(header_end) = after.find("-----\n").or_else(|| after.find("-----\r\n")) else {
            break;
        };
        if !after[..header_end].contains("PRIVATE KEY") {
            out.push_str(&rest[..start + KEY_BLOCK_START.len()]);
            rest = &rest[start + KEY_BLOCK_START.len()..];
            continue;
        }
        out.push_str(&rest[..start]);
        out.push_str("[redacted-private-key]");
        // The BEGIN header itself ends in `PRIVATE KEY-----`, so the closing
        // marker is only meaningful past that header.
        let body = &after[header_end..];
        rest = match body.find(KEY_BLOCK_END) {
            Some(end) => &body[end + KEY_BLOCK_END.len()..],
            None => "",
        };
    }
    out.push_str(rest);
    out
}

/// Masks credentials that commonly land in prompts. This runs before anything
/// is written to the archive, so a redacted secret never reaches the ZIP.
pub fn redact(text: &str) -> String {
    let text = redact_key_blocks(text);
    let mut out = String::with_capacity(text.len());
    let mut characters = text.char_indices().peekable();
    while let Some(&(start, character)) = characters.peek() {
        if !is_token_char(character) {
            out.push(character);
            characters.next();
            continue;
        }
        let mut end = start;
        while let Some(&(offset, character)) = characters.peek() {
            if !is_token_char(character) {
                break;
            }
            end = offset + character.len_utf8();
            characters.next();
        }
        let token = &text[start..end];
        if looks_like_secret(token) {
            out.push_str(REDACTED);
        } else {
            out.push_str(token);
        }
    }
    out
}

/// Returns the contents of the first `<tag>...</tag>` pair, if present.
pub fn extract_tag<'a>(text: &'a str, tag: &str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(text[start..end].trim())
}

/// True when the text opens with one of the given `<tag>` wrappers, which both
/// agents use to inject machinery that the human never typed.
pub fn opens_with_tag(text: &str, tags: &[&str]) -> bool {
    let trimmed = text.trim_start();
    tags.iter()
        .any(|tag| trimmed.starts_with(&format!("<{tag}")))
}

/// Trims a message and, when a cap is set, truncates it on a character
/// boundary with a visible marker so truncation is never silent.
pub fn normalize(text: &str, max_chars: Option<usize>) -> String {
    let trimmed = text.trim();
    let Some(limit) = max_chars else {
        return trimmed.to_string();
    };
    if trimmed.chars().count() <= limit {
        return trimmed.to_string();
    }
    let kept: String = trimmed.chars().take(limit).collect();
    format!("{kept}… [truncated]")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn masks_known_credential_shapes() {
        let masked = redact("use sk-abcdefghijklmnopqrstuvwxyz012345 now");
        assert_eq!(masked, format!("use {REDACTED} now"));
        assert!(redact("AKIAIOSFODNN7EXAMPLE").contains(REDACTED));
        assert!(redact("token=ghp_0123456789012345678901234567890123456").contains(REDACTED));
    }

    #[test]
    fn leaves_ordinary_prose_alone() {
        let prose = "I need an sk- style key for the AWS AKIA prefix, dashes and all.";
        assert_eq!(redact(prose), prose);
        assert_eq!(redact("skater-boy-was-here"), "skater-boy-was-here");
    }

    #[test]
    fn masks_private_key_blocks_but_not_certificates() {
        let key = "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEow==\n-----END RSA PRIVATE KEY-----\nafter";
        let masked = redact(key);
        assert!(masked.contains("[redacted-private-key]"));
        assert!(!masked.contains("MIIEow"));
        assert!(masked.starts_with("before"));
        assert!(masked.ends_with("after"));

        let cert = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----";
        assert_eq!(redact(cert), cert);
    }

    #[test]
    fn preserves_non_ascii_text() {
        let text = "héllo wörld — ünïcode ✅ 日本語";
        assert_eq!(redact(text), text);
    }

    #[test]
    fn reads_tags_and_detects_wrappers() {
        assert_eq!(
            extract_tag("<command-args> ship it </command-args>", "command-args"),
            Some("ship it")
        );
        assert_eq!(extract_tag("no tags here", "command-args"), None);
        assert!(opens_with_tag(
            "  <environment_context>x",
            &["environment_context"]
        ));
        assert!(!opens_with_tag(
            "hello <environment_context>",
            &["environment_context"]
        ));
    }

    #[test]
    fn truncates_on_character_boundaries() {
        assert_eq!(normalize("  hi  ", None), "hi");
        assert_eq!(normalize("abcdef", Some(3)), "abc… [truncated]");
        assert_eq!(normalize("日本語です", Some(2)), "日本… [truncated]");
        assert_eq!(normalize("abc", Some(10)), "abc");
    }
}
