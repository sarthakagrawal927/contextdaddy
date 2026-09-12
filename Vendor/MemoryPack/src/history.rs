//! Reads the prompt histories both CLIs keep outside their transcripts.
//!
//! `~/.claude/history.jsonl` and `~/.codex/history.jsonl` record every prompt
//! the person submitted, and they reach much further back than the session
//! transcripts, which both CLIs prune. A prompt whose session has been pruned
//! survives only here, so these files are the difference between recent
//! history and all of it.
//!
//! They hold prompts alone. A session recovered from history therefore has no
//! replies, which is why it is merged into a transcript-backed session
//! wherever one still exists.

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use serde_json::Value;

use crate::options::Options;
use crate::session::{Message, Role, Session, Source};
use crate::text;

/// One remembered prompt, before it is attached to a session.
struct Entry {
    session_id: String,
    at: f64,
    text: String,
    project: Option<String>,
}

fn string_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key)?.as_str()
}

/// Text a person pasted into their prompt. The CLI stores a hash instead of
/// the content once the paste is large, so only recorded content is used.
fn pasted_text(entry: &Value) -> String {
    let Some(pasted) = entry.get("pastedContents").and_then(Value::as_object) else {
        return String::new();
    };
    pasted
        .values()
        .filter_map(|item| item.get("content").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

fn read_claude<R: BufRead>(reader: R) -> Vec<Entry> {
    let mut entries = Vec::new();
    for line in reader.lines().map_while(Result::ok) {
        let Ok(row) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let (Some(session_id), Some(display), Some(stamp)) = (
            string_field(&row, "sessionId"),
            string_field(&row, "display"),
            row.get("timestamp").and_then(Value::as_f64),
        ) else {
            continue;
        };
        let pasted = pasted_text(&row);
        let text = if pasted.is_empty() {
            display.to_string()
        } else {
            format!("{display}\n{pasted}")
        };
        entries.push(Entry {
            session_id: session_id.to_string(),
            // Claude records milliseconds here, unlike its transcripts.
            at: stamp / 1000.0,
            text,
            project: string_field(&row, "project").map(str::to_string),
        });
    }
    entries
}

fn read_codex<R: BufRead>(reader: R) -> Vec<Entry> {
    let mut entries = Vec::new();
    for line in reader.lines().map_while(Result::ok) {
        let Ok(row) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let (Some(session_id), Some(text), Some(at)) = (
            string_field(&row, "session_id"),
            string_field(&row, "text"),
            row.get("ts").and_then(Value::as_f64),
        ) else {
            continue;
        };
        entries.push(Entry {
            session_id: session_id.to_string(),
            at,
            text: text.to_string(),
            project: None,
        });
    }
    entries
}

fn load(path: &Path, source: Source) -> Vec<Entry> {
    let Ok(file) = File::open(path) else {
        return Vec::new();
    };
    let reader = BufReader::new(file);
    match source {
        Source::ClaudeCode => read_claude(reader),
        Source::Codex => read_codex(reader),
    }
}

/// Folds remembered prompts into `sessions`, extending the ones still backed
/// by a transcript and rebuilding the ones whose transcript is gone. Returns
/// how many prompts and sessions were recovered.
fn fold(
    sessions: &mut Vec<Session>,
    entries: Vec<Entry>,
    source: Source,
    titles: &HashMap<String, String>,
    options: &Options,
) -> (usize, usize) {
    let mut index: HashMap<String, usize> = sessions
        .iter()
        .enumerate()
        .filter(|(_, session)| session.source == source)
        .map(|(position, session)| (session.id.clone(), position))
        .collect();

    let mut added_prompts = 0;
    let mut added_sessions = 0;
    for entry in entries {
        let id = format!("{}-{}", source.id_prefix(), entry.session_id);
        let body = match prepare(&entry.text, options) {
            Some(body) => body,
            None => continue,
        };

        let position = match index.get(&id) {
            Some(position) => *position,
            None => {
                sessions.push(Session {
                    id: id.clone(),
                    source,
                    title: titles.get(&entry.session_id).cloned(),
                    project: entry.project.clone(),
                    started_at: entry.at,
                    messages: Vec::new(),
                    // A session rebuilt from prompt history has no transcript,
                    // so there is nothing to account for.
                    stats: crate::efficiency::SessionStats::default(),
                });
                added_sessions += 1;
                index.insert(id, sessions.len() - 1);
                sessions.len() - 1
            }
        };

        let session = &mut sessions[position];
        // The transcript is the better record when it already has the prompt.
        if session.messages.iter().any(|message| message.text == body) {
            continue;
        }
        if session.project.is_none() {
            session.project = entry.project;
        }
        session.messages.push(Message {
            role: Role::User,
            text: body,
            at: entry.at,
            model: None,
        });
        added_prompts += 1;
    }

    for session in sessions.iter_mut() {
        session
            .messages
            .sort_by(|left, right| left.at.total_cmp(&right.at));
        if let Some(first) = session.messages.first() {
            session.started_at = first.at;
        }
    }
    (added_prompts, added_sessions)
}

fn prepare(raw: &str, options: &Options) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let body = if options.redact {
        text::redact(trimmed)
    } else {
        trimmed.to_string()
    };
    let body = text::normalize(&body, options.max_message_chars);
    (!body.is_empty()).then_some(body)
}

/// Merges whichever histories the caller asked for.
pub fn merge(
    sessions: &mut Vec<Session>,
    directory: &Path,
    source: Source,
    titles: &HashMap<String, String>,
    options: &Options,
) -> (usize, usize) {
    let entries = load(&directory.join("history.jsonl"), source);
    if entries.is_empty() {
        return (0, 0);
    }
    fold(sessions, entries, source, titles, options)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn base(id: &str, source: Source, text: &str, at: f64) -> Session {
        Session {
            id: id.into(),
            source,
            title: None,
            project: None,
            started_at: at,
            messages: vec![Message {
                role: Role::User,
                text: text.into(),
                at,
                model: None,
            }],
            stats: crate::efficiency::SessionStats::default(),
        }
    }

    #[test]
    fn reads_both_history_formats() {
        let claude = read_claude(Cursor::new(
            r#"{"display":"ship it","timestamp":1788019427000,"project":"/repo","sessionId":"s1","pastedContents":{"1":{"type":"text","content":"pasted body"}}}"#,
        ));
        assert_eq!(claude.len(), 1);
        assert_eq!(claude[0].session_id, "s1");
        assert_eq!(claude[0].at, 1_788_019_427.0);
        assert_eq!(claude[0].text, "ship it\npasted body");
        assert_eq!(claude[0].project.as_deref(), Some("/repo"));

        let codex = read_codex(Cursor::new(
            r#"{"session_id":"t1","ts":1788019427,"text":"do the thing"}"#,
        ));
        assert_eq!(codex.len(), 1);
        assert_eq!(codex[0].at, 1_788_019_427.0);
        assert_eq!(codex[0].text, "do the thing");
    }

    #[test]
    fn ignores_a_paste_stored_only_as_a_hash() {
        let rows = read_claude(Cursor::new(
            r#"{"display":"ask","timestamp":1000,"sessionId":"s1","pastedContents":{"1":{"type":"text","contentHash":"abc"}}}"#,
        ));
        assert_eq!(rows[0].text, "ask");
    }

    #[test]
    fn rebuilds_a_session_whose_transcript_is_gone() {
        let mut sessions = vec![base("claude-s1", Source::ClaudeCode, "kept", 100.0)];
        let entries = vec![
            Entry {
                session_id: "s1".into(),
                at: 90.0,
                text: "earlier".into(),
                project: None,
            },
            Entry {
                session_id: "pruned".into(),
                at: 50.0,
                text: "long gone".into(),
                project: Some("/old".into()),
            },
        ];
        let titles = HashMap::from([("pruned".to_string(), "Old thread".to_string())]);
        let (prompts, added) = fold(
            &mut sessions,
            entries,
            Source::ClaudeCode,
            &titles,
            &Options::default(),
        );

        assert_eq!((prompts, added), (2, 1));
        assert_eq!(sessions.len(), 2);
        let existing = sessions.iter().find(|s| s.id == "claude-s1").unwrap();
        assert_eq!(
            existing
                .messages
                .iter()
                .map(|m| m.text.as_str())
                .collect::<Vec<_>>(),
            vec!["earlier", "kept"]
        );
        assert_eq!(existing.started_at, 90.0);

        let rebuilt = sessions.iter().find(|s| s.id == "claude-pruned").unwrap();
        assert_eq!(rebuilt.title.as_deref(), Some("Old thread"));
        assert_eq!(rebuilt.project.as_deref(), Some("/old"));
        assert_eq!(rebuilt.messages.len(), 1);
    }

    #[test]
    fn never_duplicates_a_prompt_the_transcript_already_holds() {
        let mut sessions = vec![base("codex-t1", Source::Codex, "same ask", 100.0)];
        let entries = vec![Entry {
            session_id: "t1".into(),
            at: 100.0,
            text: "same ask".into(),
            project: None,
        }];
        let (prompts, added) = fold(
            &mut sessions,
            entries,
            Source::Codex,
            &HashMap::new(),
            &Options::default(),
        );
        assert_eq!((prompts, added), (0, 0));
        assert_eq!(sessions[0].messages.len(), 1);
    }
}
