//! Reads Codex rollouts from `~/.codex/sessions/YYYY/MM/DD`.
//!
//! A rollout records the whole turn stream. Only `response_item` messages
//! carry conversation text; the `event_msg` envelopes restate items already
//! recorded, and the user channel additionally carries injected context the
//! person never typed.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use serde_json::Value;
use walkdir::WalkDir;

use crate::efficiency::{SessionStats, Tokens};
use crate::input;
use crate::options::{Collection, Options};
use crate::session::{Message, Role, Session, Source};
use crate::text;

/// Wrappers Codex injects into the user channel.
const INJECTED_TAGS: &[&str] = &[
    "environment_context",
    "recommended_plugins",
    "turn_aborted",
    "subagent_notification",
    "user_instructions",
    "INSTRUCTIONS",
    "app-context",
    "codex_internal_context",
    "in-app-browser-context",
    "chrome_tabs",
    "ambient_state",
];

/// The instruction preamble Codex prepends to the first user turn.
const INSTRUCTION_PREFIXES: &[&str] = &["# AGENTS.md", "# Global agent instructions"];

fn string_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key)?.as_str()
}

/// Joins the readable blocks of a Codex content array. `encrypted_content` and
/// other opaque blocks carry no text and are skipped.
fn block_text(content: &Value) -> String {
    let Some(blocks) = content.as_array() else {
        return String::new();
    };
    blocks
        .iter()
        .filter(|block| {
            matches!(
                block.get("type").and_then(Value::as_str),
                Some("input_text" | "output_text" | "text" | "summary_text")
            )
        })
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Removes the `<image …>` block the CLI wraps around a pasted image. It
/// carries a clipboard temp path rather than anything the person wrote, and
/// left in place that path becomes part of the analysed prompt text.
fn strip_image_blocks(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("<image ") {
        let Some(end) = rest[start..].find("</image>") else {
            break;
        };
        out.push_str(&rest[..start]);
        rest = &rest[start + end + "</image>".len()..];
    }
    out.push_str(rest);
    out
}

/// When the person attaches files, the CLI prefixes their prompt with a
/// manifest of paths and marks the prompt itself with `## My request:`.
fn unwrap_file_manifest(text: &str) -> &str {
    const MANIFEST: &str = "# Files mentioned by the user:";
    const REQUEST: &str = "## My request:";
    if !text.trim_start().starts_with(MANIFEST) {
        return text;
    }
    match text.find(REQUEST) {
        Some(start) => text[start + REQUEST.len()..].trim_start(),
        None => text,
    }
}

/// Reduces a user turn to the words the person actually wrote.
fn clean_prompt(raw: &str) -> String {
    strip_image_blocks(unwrap_file_manifest(raw))
        .trim()
        .to_string()
}

fn is_injected(candidate: &str) -> bool {
    let trimmed = candidate.trim();
    trimmed.is_empty()
        || text::opens_with_tag(trimmed, INJECTED_TAGS)
        || INSTRUCTION_PREFIXES
            .iter()
            .any(|prefix| trimmed.starts_with(prefix))
}

#[derive(Default)]
struct Draft {
    identified: bool,
    id: Option<String>,
    session_id: Option<String>,
    project: Option<String>,
    model: Option<String>,
    is_subagent: bool,
    stats: SessionStats,
    messages: Vec<Message>,
    /// Prompts found only inside a compaction record. Compaction rewrites the
    /// turn history, and when a thread resumes from an earlier rollout the
    /// original turns are not in this file at all.
    compacted: Vec<Message>,
}

/// Applies the rollout's own `session_meta`. A resumed thread writes further
/// meta rows that omit `thread_source`, so only the first row identifies it.
fn read_meta(payload: &Value, draft: &mut Draft) {
    if draft.identified {
        return;
    }
    draft.identified = true;
    draft.id = string_field(payload, "id").map(str::to_string);
    draft.session_id = string_field(payload, "session_id").map(str::to_string);
    draft.project = string_field(payload, "cwd").map(str::to_string);
    draft.is_subagent = string_field(payload, "thread_source") == Some("subagent");
}

/// Codex reports usage as a running total per session, so the last event wins.
fn record_token_count(payload: &Value, stats: &mut SessionStats) {
    if string_field(payload, "type") != Some("token_count") {
        return;
    }
    let Some(usage) = payload
        .get("info")
        .and_then(|info| info.get("total_token_usage"))
    else {
        return;
    };
    // One token_count event is one API turn. Assistant messages are far fewer
    // than turns, because a turn spent on tool calls produces no message, so
    // counting messages here would inflate the per-turn cost of every session.
    stats.count_turn();
    let read = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    stats.set_cumulative_tokens(Tokens {
        input: read("input_tokens"),
        output: read("output_tokens"),
        cache_read: read("cached_input_tokens"),
        cache_write: read("cache_write_input_tokens"),
        reasoning: read("reasoning_output_tokens"),
    });
}

/// Codex wraps shell work in a script, so the command is nested inside the
/// call's input rather than being the input.
fn shell_commands(input: &str) -> Vec<String> {
    const KEY: &str = "\"cmd\":\"";
    let mut found = Vec::new();
    let mut rest = input;
    while let Some(start) = rest.find(KEY) {
        rest = &rest[start + KEY.len()..];
        let mut command = String::new();
        let mut characters = rest.chars();
        while let Some(character) = characters.next() {
            match character {
                '"' => break,
                '\\' => {
                    // A escaped character inside the JSON string.
                    if let Some(next) = characters.next() {
                        command.push(if next == 'n' { ' ' } else { next });
                    }
                }
                _ => command.push(character),
            }
        }
        if !command.trim().is_empty() {
            found.push(command);
        }
    }
    found
}

fn record_tool_call(payload: &Value, stats: &mut SessionStats) {
    match string_field(payload, "type") {
        Some("custom_tool_call" | "function_call") => {}
        Some("custom_tool_call_output" | "function_call_output") => {
            let bytes = payload
                .get("output")
                .map(|o| o.to_string().len() as u64)
                .unwrap_or(0);
            stats.record_result(bytes, false);
            return;
        }
        _ => return,
    }
    let name = string_field(payload, "name").unwrap_or("unknown");
    let input = payload
        .get("input")
        .or_else(|| payload.get("arguments"))
        .map(Value::to_string)
        .unwrap_or_default();
    stats.record_tool(name, &input);
    for command in shell_commands(&input) {
        stats.record_command(&command);
    }
}

fn read_lines<R: BufRead>(reader: R, options: &Options) -> Draft {
    let mut draft = Draft::default();
    // A resumed thread can re-record earlier items; ids keep them unique.
    let mut seen = HashSet::new();

    for line in reader.lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let Some(payload) = entry.get("payload") else {
            continue;
        };

        match string_field(&entry, "type").unwrap_or_default() {
            "session_meta" => {
                read_meta(payload, &mut draft);
                continue;
            }
            "turn_context" => {
                if let Some(model) = string_field(payload, "model") {
                    draft.model = Some(model.to_string());
                }
                continue;
            }
            "compacted" => {
                let at = string_field(&entry, "timestamp").and_then(crate::time::epoch_seconds);
                let history = payload.get("replacement_history").and_then(Value::as_array);
                if let (Some(at), Some(history)) = (at, history) {
                    for item in history {
                        if string_field(item, "type") != Some("message")
                            || string_field(item, "role") != Some("user")
                        {
                            continue;
                        }
                        let Some(content) = item.get("content") else {
                            continue;
                        };
                        let raw = clean_prompt(&block_text(content));
                        if is_injected(&raw) {
                            continue;
                        }
                        if let Some(body) = prepare(&raw, options) {
                            // The original turn time is not recorded here, so
                            // the compaction's own time is the honest stamp.
                            draft.compacted.push(Message {
                                role: Role::User,
                                text: body,
                                at,
                                model: None,
                            });
                        }
                    }
                }
                continue;
            }
            "event_msg" => {
                if options.include_usage {
                    record_token_count(payload, &mut draft.stats);
                }
                continue;
            }
            "response_item" => {
                if options.include_usage {
                    record_tool_call(payload, &mut draft.stats);
                }
            }
            _ => continue,
        }

        if string_field(payload, "type") != Some("message") {
            continue;
        }
        let role = match string_field(payload, "role") {
            Some("user") => Role::User,
            Some("assistant") => Role::Assistant,
            // `developer` carries harness instructions, not conversation.
            _ => continue,
        };
        if role == Role::Assistant && !options.include_assistant {
            continue;
        }
        if let Some(id) = string_field(payload, "id") {
            if !seen.insert(id.to_string()) {
                continue;
            }
        }

        let Some(content) = payload.get("content") else {
            continue;
        };
        let raw = if role == Role::User {
            clean_prompt(&block_text(content))
        } else {
            block_text(content)
        };
        if role == Role::User && is_injected(&raw) {
            continue;
        }
        let Some(at) = string_field(&entry, "timestamp").and_then(crate::time::epoch_seconds)
        else {
            continue;
        };

        let Some(body) = prepare(&raw, options) else {
            continue;
        };
        draft.messages.push(Message {
            role,
            text: body,
            at,
            model: if role == Role::Assistant {
                draft.model.clone()
            } else {
                None
            },
        });
    }

    let present: HashSet<&str> = draft
        .messages
        .iter()
        .filter(|message| message.role == Role::User)
        .map(|message| message.text.as_str())
        .collect();
    let recovered: Vec<Message> = draft
        .compacted
        .iter()
        .filter(|candidate| !present.contains(candidate.text.as_str()))
        .cloned()
        .collect();
    drop(present);
    let mut deduped: Vec<Message> = Vec::new();
    for message in recovered {
        // Every compaction window restates the same turns.
        if !deduped.iter().any(|kept| kept.text == message.text) {
            deduped.push(message);
        }
    }
    draft.messages.extend(deduped);
    draft.compacted.clear();

    draft
}

/// Applies redaction and truncation, returning `None` for empty text.
fn prepare(raw: &str, options: &Options) -> Option<String> {
    let body = if options.redact {
        text::redact(raw)
    } else {
        raw.to_string()
    };
    let body = text::normalize(&body, options.max_message_chars);
    (!body.is_empty()).then_some(body)
}

/// Reads `~/.codex/session_index.jsonl`, which names threads the CLI titled.
/// It outlives the rollouts, so it can still name a pruned thread.
pub fn read_titles(codex_dir: &Path) -> HashMap<String, String> {
    let mut titles = HashMap::new();
    let Ok(file) = File::open(codex_dir.join("session_index.jsonl")) else {
        return titles;
    };
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let (Some(id), Some(name)) = (
            string_field(&entry, "id"),
            string_field(&entry, "thread_name"),
        ) {
            titles.insert(id.to_string(), name.to_string());
        }
    }
    titles
}

pub fn collect_checked(codex_dir: &Path, options: &Options) -> Result<Collection, String> {
    // The session index is outside the selected transcript roots and may be a
    // symlink or contain newer metadata. Strict cutoff exports use the parser's
    // derived title fallback so only stable, selected transcripts are read.
    let titles = titles_for_collection(codex_dir, options);

    let mut collected = Vec::new();
    let mut result = Collection::default();
    for root in [
        codex_dir.join("sessions"),
        codex_dir.join("archived_sessions"),
    ] {
        if !root.is_dir() {
            continue;
        }
        for entry in WalkDir::new(&root).into_iter().filter_map(Result::ok) {
            let path = entry.path();
            if !entry.file_type().is_file() || path.extension().is_some_and(|ext| ext != "jsonl") {
                continue;
            }
            let metadata = match input::regular_metadata(path) {
                Ok(metadata) => metadata,
                Err(_) if options.modified_before.is_some() => {
                    return Err("selected transcript became unavailable".into())
                }
                Err(_) => {
                    result.skipped_files += 1;
                    continue;
                }
            };
            if let Some(cutoff) = options.modified_before {
                if !input::is_before_cutoff(input::modified_epoch(&metadata), cutoff) {
                    result.skipped_files += 1;
                    continue;
                }
            }
            let (file, before) = match input::open_regular_expected(path, Some(&metadata)) {
                Ok(value) => value,
                Err(_) if options.modified_before.is_some() => {
                    return Err("selected transcript changed before read".into())
                }
                Err(_) => {
                    result.skipped_files += 1;
                    continue;
                }
            };
            let mut draft = read_lines(BufReader::new(&file), options);
            if input::unchanged(path, &file, &before).is_err() && options.modified_before.is_some()
            {
                return Err("selected transcript changed during read".into());
            }
            if draft.messages.is_empty() || (draft.is_subagent && !options.include_subagents) {
                continue;
            }

            let stem = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or_default();
            let id = draft
                .id
                .clone()
                .or_else(|| draft.session_id.clone())
                .unwrap_or_else(|| stem.to_string());
            let session_id = format!("{}-{id}", Source::Codex.id_prefix());
            result.source_files += 1;
            result.source_bytes += before.len();
            result
                .sources
                .push(crate::source::SourceFile::from_metadata(
                    path,
                    &before,
                    session_id.clone(),
                ));
            let title = draft
                .id
                .as_ref()
                .and_then(|key| titles.get(key))
                .or_else(|| draft.session_id.as_ref().and_then(|key| titles.get(key)))
                .cloned();

            draft
                .messages
                .sort_by(|left, right| left.at.total_cmp(&right.at));
            collected.push(Session {
                id: session_id,
                source: Source::Codex,
                title,
                project: draft.project.clone(),
                started_at: draft.messages[0].at,
                messages: draft.messages,
                stats: draft.stats,
            });
        }
    }
    result.sessions = collected;
    Ok(result)
}

fn titles_for_collection(codex_dir: &Path, options: &Options) -> HashMap<String, String> {
    if options.modified_before.is_some() {
        HashMap::new()
    } else {
        read_titles(codex_dir)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn parse(lines: &str) -> Draft {
        read_lines(Cursor::new(lines.to_string()), &Options::default())
    }

    #[test]
    fn strict_cutoff_does_not_read_external_session_index() {
        let options = Options {
            modified_before: Some(100.0),
            ..Options::default()
        };
        assert!(titles_for_collection(Path::new("/does-not-exist"), &options).is_empty());
    }

    const STAMP: &str = r#""timestamp":"2026-08-25T07:57:31.000Z""#;

    fn message_line(role: &str, text: &str, id: &str) -> String {
        format!(
            r#"{{{STAMP},"type":"response_item","payload":{{"type":"message","id":"{id}","role":"{role}","content":[{{"type":"input_text","text":{}}}]}}}}"#,
            serde_json::to_string(text).unwrap()
        )
    }

    #[test]
    fn keeps_conversation_and_records_metadata() {
        let transcript = [
            format!(
                r#"{{{STAMP},"type":"session_meta","payload":{{"id":"thread-1","session_id":"sess-1","cwd":"/repo","thread_source":"main"}}}}"#
            ),
            format!(r#"{{{STAMP},"type":"turn_context","payload":{{"model":"gpt-5.6-sol"}}}}"#),
            message_line("user", "pack my sessions", "m1"),
            message_line("assistant", "on it", "m2"),
        ]
        .join("\n");
        let draft = parse(&transcript);

        assert_eq!(draft.id.as_deref(), Some("thread-1"));
        assert_eq!(draft.project.as_deref(), Some("/repo"));
        assert!(!draft.is_subagent);
        assert_eq!(draft.messages.len(), 2);
        assert_eq!(draft.messages[0].text, "pack my sessions");
        assert_eq!(draft.messages[1].model.as_deref(), Some("gpt-5.6-sol"));
    }

    #[test]
    fn drops_injected_context_and_non_conversation_rows() {
        let transcript = [
            message_line("user", "<environment_context>cwd=/repo</environment_context>", "m1"),
            message_line("user", "# AGENTS.md instructions\n<INSTRUCTIONS>do things</INSTRUCTIONS>", "m2"),
            message_line("user", "<recommended_plugins>x</recommended_plugins>", "m3"),
            message_line("developer", "harness rules", "m4"),
            format!(
                r#"{{{STAMP},"type":"event_msg","payload":{{"type":"item_completed","item":{{"type":"Reasoning"}}}}}}"#
            ),
            format!(
                r#"{{{STAMP},"type":"response_item","payload":{{"type":"agent_message","id":"a1","content":[{{"type":"input_text","text":"NEW_TASK"}}]}}}}"#
            ),
        ]
        .join("\n");
        assert!(parse(&transcript).messages.is_empty());
    }

    #[test]
    fn drops_the_harness_context_codex_injects_mid_thread() {
        let transcript = [
            message_line("user", "<codex_internal_context source=\"goal\">\nContinue toward the goal.\n</codex_internal_context>", "m1"),
            message_line("user", "<in-app-browser-context>\ntabs\n</in-app-browser-context>", "m2"),
            message_line("user", "a real ask", "m3"),
        ]
        .join("\n");
        let draft = parse(&transcript);
        assert_eq!(draft.messages.len(), 1);
        assert_eq!(draft.messages[0].text, "a real ask");
    }

    #[test]
    fn deduplicates_items_a_resumed_thread_re_records() {
        let transcript = [
            message_line("user", "first ask", "m1"),
            message_line("user", "first ask", "m1"),
            message_line("user", "second ask", "m2"),
        ]
        .join("\n");
        assert_eq!(parse(&transcript).messages.len(), 2);
    }

    #[test]
    fn reduces_a_prompt_to_what_the_person_wrote() {
        let wrapped = "<image name=[Image #1] path=\"/var/folders/T/codex-clipboard-x.png\">\n</image>\nfix the header";
        assert_eq!(clean_prompt(wrapped), "fix the header");

        let manifest = "# Files mentioned by the user:\n\n## prd.md: /Users/me/prd.md\n\n## My request:\nbuild this";
        assert_eq!(clean_prompt(manifest), "build this");

        assert_eq!(clean_prompt("just a prompt"), "just a prompt");
        // An unterminated wrapper must not swallow the prompt.
        assert_eq!(
            clean_prompt("<image src=x\nkeep me"),
            "<image src=x\nkeep me"
        );
    }

    #[test]
    fn strips_the_clipboard_path_from_a_kept_prompt() {
        let transcript = message_line(
            "user",
            "<image name=[Image #1] path=\"/var/folders/T/codex-clipboard-x.png\">\n</image>\ncentre the cross",
            "m1",
        );
        let draft = parse(&transcript);
        assert_eq!(draft.messages[0].text, "centre the cross");
        assert!(!draft.messages[0].text.contains("codex-clipboard"));
    }

    #[test]
    fn recovers_a_prompt_that_survives_only_in_compaction() {
        let compaction = |window: &str| {
            format!(
                r#"{{{STAMP},"type":"compacted","payload":{{"window_id":"{window}","replacement_history":[{{"type":"message","role":"user","content":[{{"type":"input_text","text":"lost to compaction"}}]}},{{"type":"message","role":"user","content":[{{"type":"input_text","text":"still here"}}]}},{{"type":"message","role":"developer","content":[{{"type":"input_text","text":"harness rules"}}]}}]}}}}"#
            )
        };
        let transcript = [
            message_line("user", "still here", "m1"),
            compaction("w1"),
            // A second window restates the same turns.
            compaction("w2"),
        ]
        .join("\n");

        let texts: Vec<String> = parse(&transcript)
            .messages
            .iter()
            .map(|m| m.text.clone())
            .collect();
        assert_eq!(texts, vec!["still here", "lost to compaction"]);
    }

    #[test]
    fn flags_a_subagent_rollout() {
        let transcript = [
            format!(
                r#"{{{STAMP},"type":"session_meta","payload":{{"id":"t","thread_source":"subagent"}}}}"#
            ),
            message_line("user", "delegated work", "m1"),
        ]
        .join("\n");
        assert!(parse(&transcript).is_subagent);
    }

    #[test]
    fn a_later_meta_row_cannot_un_flag_a_subagent() {
        let transcript = [
            format!(
                r#"{{{STAMP},"type":"session_meta","payload":{{"id":"t","thread_source":"subagent"}}}}"#
            ),
            message_line("user", "delegated work", "m1"),
            format!(r#"{{{STAMP},"type":"session_meta","payload":{{"id":"t","cwd":"/repo"}}}}"#),
        ]
        .join("\n");
        let draft = parse(&transcript);
        assert!(draft.is_subagent);
        assert_eq!(draft.id.as_deref(), Some("t"));
    }

    #[test]
    fn skips_opaque_blocks_and_honours_options() {
        let transcript = format!(
            r#"{{{STAMP},"type":"response_item","payload":{{"type":"message","id":"m1","role":"user","content":[{{"type":"encrypted_content","encrypted_content":"gAAA"}},{{"type":"input_text","text":"key sk-abcdefghijklmnopqrstuvwxyz012345"}}]}}}}"#
        );
        let draft = parse(&transcript);
        assert_eq!(draft.messages.len(), 1);
        assert!(!draft.messages[0].text.contains("gAAA"));
        assert!(draft.messages[0].text.contains("[redacted-secret]"));

        let options = Options {
            redact: false,
            ..Options::default()
        };
        let raw = read_lines(Cursor::new(transcript), &options);
        assert!(raw.messages[0]
            .text
            .contains("sk-abcdefghijklmnopqrstuvwxyz012345"));
    }
}
