//! Reads Claude Code transcripts from `~/.claude/projects`.
//!
//! Each session is one JSONL file named for its session id. Most `user` rows
//! are tool-result carriers rather than anything a human typed, so the reader
//! keeps only rows the CLI attributes to a person.

use std::collections::{BTreeMap, HashSet};
use std::io::{BufRead, BufReader};
use std::path::Path;

use serde_json::Value;
use walkdir::WalkDir;

use crate::efficiency::{SessionStats, Tokens};
use crate::input;
use crate::options::{Collection, Options};
use crate::session::{Message, Role, Session, Source};
use crate::text;

/// `promptSource` values that mean a person typed or queued the text.
///
/// `sdk` is deliberately absent. It marks a programmatic invocation, which
/// carries a generated prompt rather than anything a person wrote — on the
/// corpus this was built against, 128 such rows were one injected code-review
/// system prompt accounting for half of all prompt text. No `sdk` row is ever
/// marked `origin.kind: "human"`, which is the CLI's own signal for authorship.
const HUMAN_PROMPT_SOURCES: &[&str] = &["typed", "queued"];

/// Wrappers the CLI injects into the user channel that no human wrote.
const INJECTED_TAGS: &[&str] = &[
    "task-notification",
    "system-reminder",
    "local-command-stdout",
    "command-message",
    "bash-stdout",
    "bash-stderr",
    "user-prompt-submit-hook",
];

/// Status lines the CLI records as user turns.
const STATUS_NOTICES: &[&str] = &[
    "[Request interrupted by user]",
    "[Request interrupted by user for tool use]",
    "API Error",
];

const COMPACTION_PREFIX: &str = "This session is being continued from a previous conversation";

fn string_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key)?.as_str()
}

fn is_true(value: &Value, key: &str) -> bool {
    value.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// Rebuilds `/command args` from the CLI's expanded slash-command payload, so
/// an invoked command still reads as the intent the person expressed.
fn unwrap_slash_command(raw: &str) -> Option<String> {
    let name = text::extract_tag(raw, "command-name")?;
    let args = text::extract_tag(raw, "command-args").unwrap_or_default();
    let rebuilt = format!("{name} {args}").trim().to_string();
    (!rebuilt.is_empty()).then_some(rebuilt)
}

/// Joins the `text` blocks of a structured content array, ignoring tool calls,
/// tool results, thinking, and images.
fn prose_blocks(content: &Value) -> String {
    let Some(blocks) = content.as_array() else {
        return String::new();
    };
    blocks
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

fn is_droppable(candidate: &str) -> bool {
    let trimmed = candidate.trim();
    trimmed.is_empty()
        || trimmed.starts_with(COMPACTION_PREFIX)
        || text::opens_with_tag(trimmed, INJECTED_TAGS)
        || STATUS_NOTICES
            .iter()
            .any(|notice| trimmed.starts_with(notice))
}

/// Returns the human-authored text of a `user` row, if it has any.
fn user_text(entry: &Value) -> Option<String> {
    if is_true(entry, "isMeta") {
        return None;
    }
    let content = entry.get("message")?.get("content")?;

    let raw = match content {
        Value::String(value) => {
            let source = string_field(entry, "promptSource");
            match source {
                // A recorded source that is not a person (`system`) is machinery.
                Some(value) if !HUMAN_PROMPT_SOURCES.contains(&value) => return None,
                _ => value.clone(),
            }
        }
        Value::Array(_) => prose_blocks(content),
        _ => return None,
    };

    if let Some(command) = unwrap_slash_command(&raw) {
        return Some(command);
    }
    (!is_droppable(&raw)).then_some(raw)
}

fn assistant_text(entry: &Value) -> Option<String> {
    if is_true(entry, "isApiErrorMessage") {
        return None;
    }
    let prose = prose_blocks(entry.get("message")?.get("content")?);
    (!is_droppable(&prose)).then_some(prose)
}

/// The model that produced a turn. `<synthetic>` marks a locally generated
/// turn rather than a model response, so it is not reported as one.
fn assistant_model(entry: &Value) -> Option<String> {
    entry
        .get("message")
        .and_then(|message| message.get("model"))
        .and_then(Value::as_str)
        .or_else(|| string_field(entry, "slug"))
        .filter(|model| !model.starts_with('<'))
        .map(str::to_string)
}

#[derive(Default)]
struct Draft {
    title: Option<String>,
    project: Option<String>,
    messages: Vec<Message>,
    stats: SessionStats,
    /// Prompts typed while the agent was busy. The CLI records these as
    /// attachments, and a queued prompt the session never delivered appears
    /// nowhere else, so they are collected here and merged once the whole
    /// transcript is known.
    queued: Vec<Message>,
}

/// Reads a prompt the person typed into the queue. `origin.kind` is the CLI's
/// own marker for text a human wrote, so anything else is machinery.
fn queued_prompt(entry: &Value) -> Option<(String, Option<String>)> {
    let attachment = entry.get("attachment")?;
    if string_field(attachment, "type") != Some("queued_command") {
        return None;
    }
    if attachment.get("origin")?.get("kind")?.as_str() != Some("human") {
        return None;
    }
    let prompt = string_field(attachment, "prompt")?.to_string();
    Some((
        prompt,
        string_field(attachment, "timestamp").map(str::to_string),
    ))
}

/// Collects token and tool accounting from a row. This reads the parts of the
/// transcript the archive never carries: usage blocks, tool arguments, and
/// tool results.
fn record_usage(entry: &Value, kind: &str, stats: &mut SessionStats) {
    if kind == "assistant" {
        let usage = entry
            .get("message")
            .and_then(|message| message.get("usage"));
        let read = |key: &str| -> u64 {
            usage
                .and_then(|u| u.get(key))
                .and_then(Value::as_u64)
                .unwrap_or(0)
        };
        stats.record_turn(Tokens {
            input: read("input_tokens"),
            output: read("output_tokens"),
            cache_read: read("cache_read_input_tokens"),
            cache_write: read("cache_creation_input_tokens"),
            reasoning: 0,
        });
        if let Some(blocks) = entry
            .get("message")
            .and_then(|message| message.get("content"))
            .and_then(Value::as_array)
        {
            for block in blocks {
                if block.get("type").and_then(Value::as_str) != Some("tool_use") {
                    continue;
                }
                let name = string_field(block, "name").unwrap_or("unknown");
                let arguments = block.get("input").map(Value::to_string).unwrap_or_default();
                stats.record_tool(name, &arguments);
                if name == "Bash" {
                    if let Some(command) = block
                        .get("input")
                        .and_then(|i| i.get("command"))
                        .and_then(Value::as_str)
                    {
                        stats.record_command(command);
                    }
                }
            }
        }
        return;
    }
    if kind != "user" {
        return;
    }
    let Some(blocks) = entry
        .get("message")
        .and_then(|message| message.get("content"))
        .and_then(Value::as_array)
    else {
        return;
    };
    for block in blocks {
        if block.get("type").and_then(Value::as_str) != Some("tool_result") {
            continue;
        }
        let bytes = block
            .get("content")
            .map(|c| c.to_string().len() as u64)
            .unwrap_or(0);
        stats.record_result(bytes, is_true(block, "is_error"));
    }
}

/// Parses one transcript into a draft session. Exposed for tests.
fn read_lines<R: BufRead>(reader: R, options: &Options) -> (Option<String>, Draft) {
    let mut draft = Draft::default();
    let mut session_id = None;

    for line in reader.lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if session_id.is_none() {
            session_id = string_field(&entry, "sessionId").map(str::to_string);
        }
        if draft.project.is_none() {
            draft.project = string_field(&entry, "cwd").map(str::to_string);
        }

        let kind = string_field(&entry, "type").unwrap_or_default();
        if kind == "attachment" {
            if let Some((prompt, stamp)) = queued_prompt(&entry) {
                let at = stamp
                    .as_deref()
                    .or_else(|| string_field(&entry, "timestamp"))
                    .and_then(crate::time::epoch_seconds);
                if let Some(at) = at {
                    if let Some(body) = prepare(&prompt, options) {
                        draft.queued.push(Message {
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
        if kind == "ai-title" {
            if let Some(title) = string_field(&entry, "aiTitle") {
                draft.title = Some(title.to_string());
            }
            continue;
        }
        if kind != "user" && kind != "assistant" {
            continue;
        }
        if !options.include_subagents && is_true(&entry, "isSidechain") {
            continue;
        }
        // Accounted for after the subagent filter, so a session's turns and
        // tokens describe its own thread rather than its children's.
        if options.include_usage {
            record_usage(&entry, kind, &mut draft.stats);
        }

        let (role, raw) = match kind {
            "user" => (Role::User, user_text(&entry)),
            _ if !options.include_assistant => continue,
            _ => (Role::Assistant, assistant_text(&entry)),
        };
        let Some(raw) = raw else { continue };
        let Some(at) = string_field(&entry, "timestamp").and_then(crate::time::epoch_seconds)
        else {
            continue;
        };

        let body = if options.redact {
            text::redact(&raw)
        } else {
            raw
        };
        let body = text::normalize(&body, options.max_message_chars);
        if body.is_empty() {
            continue;
        }
        draft.messages.push(Message {
            role,
            text: body,
            at,
            model: if role == Role::Assistant {
                assistant_model(&entry)
            } else {
                None
            },
        });
    }

    // A queued prompt the session went on to deliver is already recorded as a
    // user turn; only the ones that never arrived are added.
    let delivered: HashSet<&str> = draft
        .messages
        .iter()
        .filter(|message| message.role == Role::User)
        .map(|message| message.text.as_str())
        .collect();
    let undelivered: Vec<Message> = draft
        .queued
        .iter()
        .filter(|queued| !delivered.contains(queued.text.as_str()))
        .cloned()
        .collect();
    drop(delivered);
    draft.messages.extend(undelivered);
    draft.queued.clear();

    (session_id, draft)
}

/// Applies redaction and truncation, returning `None` for text that carries
/// nothing worth packing.
fn prepare(raw: &str, options: &Options) -> Option<String> {
    if is_droppable(raw) {
        return None;
    }
    let body = if options.redact {
        text::redact(raw)
    } else {
        raw.to_string()
    };
    let body = text::normalize(&body, options.max_message_chars);
    (!body.is_empty()).then_some(body)
}

/// True for `projects/<slug>/<id>/subagents/<agent>.jsonl`, which holds a
/// subagent transcript rather than a session of the person's own.
fn is_subagent_transcript(path: &Path, root: &Path) -> bool {
    path.strip_prefix(root)
        .map(|relative| relative.components().count() > 2)
        .unwrap_or(false)
}

/// Reads every session under `<home>/.claude/projects`.
pub fn collect_checked(claude_dir: &Path, options: &Options) -> Result<Collection, String> {
    let root = claude_dir.join("projects");
    if !root.is_dir() {
        return Ok(Collection::default());
    }

    // Sessions are keyed by id so a transcript split across files merges.
    let mut sessions: BTreeMap<String, Session> = BTreeMap::new();
    let mut result = Collection::default();
    for entry in WalkDir::new(&root).into_iter().filter_map(Result::ok) {
        let path = entry.path();
        if !entry.file_type().is_file() || path.extension().is_some_and(|ext| ext != "jsonl") {
            continue;
        }
        if !options.include_subagents && is_subagent_transcript(path, &root) {
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
        let stem = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or_default();
        let (parsed_id, draft) = read_lines(BufReader::new(&file), options);
        if input::unchanged(path, &file, &before).is_err() && options.modified_before.is_some() {
            return Err("selected transcript changed during read".into());
        }
        if draft.messages.is_empty() {
            continue;
        }

        let id = parsed_id.unwrap_or_else(|| stem.to_string());
        let session_id = format!("{}-{id}", Source::ClaudeCode.id_prefix());
        result.source_files += 1;
        result.source_bytes += before.len();
        result
            .sources
            .push(crate::source::SourceFile::from_metadata(
                path,
                &before,
                session_id.clone(),
            ));
        let session = sessions.entry(id.clone()).or_insert_with(|| Session {
            id: session_id,
            source: Source::ClaudeCode,
            title: None,
            project: draft.project.clone(),
            started_at: draft.messages[0].at,
            messages: Vec::new(),
            stats: SessionStats::default(),
        });
        if session.title.is_none() {
            session.title = draft.title.clone();
        }
        session.stats.merge(&draft.stats);
        session.messages.extend(draft.messages);
    }

    let mut collected: Vec<Session> = sessions.into_values().collect();
    for session in &mut collected {
        session
            .messages
            .sort_by(|left, right| left.at.total_cmp(&right.at));
        session.started_at = session
            .messages
            .first()
            .map_or(session.started_at, |first| first.at);
    }
    result.sessions = collected;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn parse(lines: &str) -> Draft {
        read_lines(Cursor::new(lines.to_string()), &Options::default()).1
    }

    const STAMP: &str = r#""timestamp":"2026-08-29T16:03:47.000Z","sessionId":"abc""#;

    #[test]
    fn keeps_typed_prompts_and_assistant_prose() {
        let transcript = format!(
            concat!(
                r#"{{"type":"user","promptSource":"typed","message":{{"content":"pack my sessions"}},{stamp}}}"#,
                "\n",
                r#"{{"type":"assistant","message":{{"model":"claude-opus-5","content":[{{"type":"thinking","thinking":"hmm"}},{{"type":"text","text":"on it"}}]}},{stamp}}}"#,
                "\n",
                r#"{{"type":"ai-title","aiTitle":"Session export","sessionId":"abc"}}"#,
            ),
            stamp = STAMP
        );
        let draft = parse(&transcript);

        assert_eq!(draft.title.as_deref(), Some("Session export"));
        assert_eq!(draft.messages.len(), 2);
        assert_eq!(draft.messages[0].text, "pack my sessions");
        assert_eq!(draft.messages[1].text, "on it");
        assert_eq!(draft.messages[1].model.as_deref(), Some("claude-opus-5"));
    }

    #[test]
    fn does_not_report_a_synthetic_turn_as_a_model() {
        let transcript = format!(
            r#"{{"type":"assistant","message":{{"model":"<synthetic>","content":[{{"type":"text","text":"queued"}}]}},{stamp}}}"#,
            stamp = STAMP
        );
        assert_eq!(parse(&transcript).messages[0].model, None);
    }

    #[test]
    fn drops_the_machinery_that_rides_the_user_channel() {
        let transcript = format!(
            concat!(
                r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","content":"1000 lines"}}]}},{stamp}}}"#,
                "\n",
                r#"{{"type":"user","promptSource":"system","message":{{"content":"<task-notification>done</task-notification>"}},{stamp}}}"#,
                "\n",
                r#"{{"type":"user","isMeta":true,"message":{{"content":"caveat"}},{stamp}}}"#,
                "\n",
                r#"{{"type":"user","message":{{"content":"This session is being continued from a previous conversation. Summary:"}},{stamp}}}"#,
                "\n",
                r#"{{"type":"user","message":{{"content":[{{"type":"text","text":"[Request interrupted by user]"}}]}},{stamp}}}"#,
                "\n",
                r#"{{"type":"user","isSidechain":true,"promptSource":"typed","message":{{"content":"subagent work"}},{stamp}}}"#,
            ),
            stamp = STAMP
        );
        assert!(parse(&transcript).messages.is_empty());
    }

    #[test]
    fn rebuilds_an_invoked_slash_command() {
        let transcript = format!(
            r#"{{"type":"user","message":{{"content":"<command-name>/goal</command-name><command-message>goal</command-message><command-args>ship the packer</command-args>"}},{stamp}}}"#,
            stamp = STAMP
        );
        let draft = parse(&transcript);
        assert_eq!(draft.messages.len(), 1);
        assert_eq!(draft.messages[0].text, "/goal ship the packer");
    }

    #[test]
    fn honours_assistant_and_redaction_options() {
        let transcript = format!(
            concat!(
                r#"{{"type":"user","promptSource":"typed","message":{{"content":"key is sk-abcdefghijklmnopqrstuvwxyz012345"}},{stamp}}}"#,
                "\n",
                r#"{{"type":"assistant","message":{{"content":[{{"type":"text","text":"noted"}}]}},{stamp}}}"#,
            ),
            stamp = STAMP
        );

        let redacted = parse(&transcript);
        assert!(redacted.messages[0].text.contains("[redacted-secret]"));
        assert_eq!(redacted.messages.len(), 2);

        let options = Options {
            include_assistant: false,
            redact: false,
            ..Options::default()
        };
        let raw = read_lines(Cursor::new(transcript), &options).1;
        assert_eq!(raw.messages.len(), 1);
        assert!(raw.messages[0]
            .text
            .contains("sk-abcdefghijklmnopqrstuvwxyz012345"));
    }

    #[test]
    fn recovers_a_prompt_the_session_never_delivered() {
        let transcript = format!(
            concat!(
                r#"{{"type":"attachment","attachment":{{"type":"queued_command","prompt":"typed while busy","origin":{{"kind":"human"}},"timestamp":"2026-08-29T16:03:48.000Z"}},{stamp}}}"#,
                "\n",
                r#"{{"type":"user","promptSource":"typed","message":{{"content":"first ask"}},{stamp}}}"#,
            ),
            stamp = STAMP
        );
        let draft = parse(&transcript);
        let texts: Vec<&str> = draft
            .messages
            .iter()
            .map(|message| message.text.as_str())
            .collect();
        assert_eq!(texts, vec!["first ask", "typed while busy"]);
    }

    #[test]
    fn does_not_duplicate_a_queued_prompt_that_was_delivered() {
        let transcript = format!(
            concat!(
                r#"{{"type":"attachment","attachment":{{"type":"queued_command","prompt":"same ask","origin":{{"kind":"human"}},"timestamp":"2026-08-29T16:03:48.000Z"}},{stamp}}}"#,
                "\n",
                r#"{{"type":"user","promptSource":"queued","message":{{"content":"same ask"}},{stamp}}}"#,
            ),
            stamp = STAMP
        );
        let draft = parse(&transcript);
        assert_eq!(draft.messages.len(), 1);
        assert_eq!(draft.messages[0].text, "same ask");
    }

    #[test]
    fn ignores_attachments_that_are_not_human_prompts() {
        let transcript = format!(
            concat!(
                r#"{{"type":"attachment","attachment":{{"type":"total_tokens_reminder","tokens":900}},{stamp}}}"#,
                "\n",
                r#"{{"type":"attachment","attachment":{{"type":"queued_command","prompt":"machine issued","origin":{{"kind":"system"}},"timestamp":"2026-08-29T16:03:48.000Z"}},{stamp}}}"#,
                "\n",
                r#"{{"type":"attachment","attachment":{{"type":"queued_command","prompt":"<task-notification>done</task-notification>","origin":{{"kind":"human"}},"timestamp":"2026-08-29T16:03:48.000Z"}},{stamp}}}"#,
            ),
            stamp = STAMP
        );
        assert!(parse(&transcript).messages.is_empty());
    }

    #[test]
    fn drops_a_programmatic_sdk_invocation() {
        let transcript = format!(
            r#"{{"type":"user","promptSource":"sdk","message":{{"content":"You are a senior code reviewer. Find real issues."}},{stamp}}}"#,
            stamp = STAMP
        );
        assert!(parse(&transcript).messages.is_empty());
    }

    #[test]
    fn skips_rows_without_a_usable_timestamp() {
        let transcript = r#"{"type":"user","promptSource":"typed","message":{"content":"hi"}}"#;
        assert!(parse(transcript).messages.is_empty());
    }

    #[test]
    fn identifies_subagent_transcripts_by_depth() {
        let root = Path::new("/home/.claude/projects");
        assert!(!is_subagent_transcript(
            Path::new("/home/.claude/projects/repo/abc.jsonl"),
            root
        ));
        assert!(is_subagent_transcript(
            Path::new("/home/.claude/projects/repo/abc/subagents/agent-1.jsonl"),
            root
        ));
    }
}
