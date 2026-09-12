//! Writes the archive: a ChatGPT-shaped `conversations.json` the Memory Map
//! worker already parses, plus a manifest describing where it came from.

use std::fs::File;
use std::io::{self, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::efficiency::{self, SessionRecord};
use crate::options::Options;
use crate::session::{self, Role, Session, Source};
use crate::time;

const READ_ME: &str = "\
This archive was produced by memory-pack from Claude Code and Codex sessions
stored on one machine.

  conversations.json   Your prompts and the assistant's replies, in the same
                       shape as a ChatGPT data export. Upload this archive to
                       Memory Map exactly as it is; do not unzip it first.
  memory-pack.json     What was packed, from which source, and with which
                       options.
  efficiency.json      Token and tool accounting per session: what each one
                       cost, which calls repeated, which failed. This is what
                       the report's efficiency findings are built from.

Tool calls, tool output, reasoning traces, file contents, and attachments were
never read into this archive. Credential-shaped tokens are masked unless the
archive was built with --no-redact.

Memory Map analyses the archive in your browser. Nothing in it is uploaded to
an application server.
";

#[derive(Serialize)]
struct SourceCount {
    source: &'static str,
    sessions: usize,
    prompts: usize,
    messages: usize,
}

#[derive(Serialize)]
struct ManifestOptions {
    include_usage: bool,
    include_assistant: bool,
    include_subagents: bool,
    include_history: bool,
    redacted: bool,
    max_message_chars: Option<usize>,
}

#[derive(Serialize)]
struct SessionEntry {
    id: String,
    source: &'static str,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    project: Option<String>,
    created_at: f64,
    updated_at: f64,
    prompts: usize,
    messages: usize,
}

#[derive(Serialize)]
struct Manifest {
    format: &'static str,
    tool: &'static str,
    tool_version: &'static str,
    generated_at: f64,
    options: ManifestOptions,
    totals: Totals,
    by_source: Vec<SourceCount>,
    sessions: Vec<SessionEntry>,
}

#[derive(Clone, Copy, Default, Serialize)]
pub struct Totals {
    pub sessions: usize,
    pub prompts: usize,
    pub messages: usize,
    #[serde(skip_serializing_if = "is_zero")]
    pub earliest: f64,
    #[serde(skip_serializing_if = "is_zero")]
    pub latest: f64,
}

fn is_zero(value: &f64) -> bool {
    *value == 0.0
}

pub fn totals(sessions: &[Session]) -> Totals {
    let mut totals = Totals {
        sessions: sessions.len(),
        ..Totals::default()
    };
    for session in sessions {
        totals.prompts += session.user_message_count();
        totals.messages += session.messages.len();
        if totals.earliest == 0.0 || session.started_at < totals.earliest {
            totals.earliest = session.started_at;
        }
        if session.updated_at() > totals.latest {
            totals.latest = session.updated_at();
        }
    }
    totals
}

pub fn totals_for(sessions: &[Session], source: Source) -> Totals {
    let filtered: Vec<Session> = sessions
        .iter()
        .filter(|session| session.source == source)
        .cloned()
        .collect();
    totals(&filtered)
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs_f64())
        .unwrap_or_default()
}

fn build_manifest(sessions: &[Session], options: &Options) -> Manifest {
    let by_source = [Source::ClaudeCode, Source::Codex]
        .into_iter()
        .map(|source| {
            let counts = totals_for(sessions, source);
            SourceCount {
                source: source.slug(),
                sessions: counts.sessions,
                prompts: counts.prompts,
                messages: counts.messages,
            }
        })
        .filter(|entry| entry.sessions > 0)
        .collect();

    Manifest {
        format: "memory-pack/1",
        tool: env!("CARGO_PKG_NAME"),
        tool_version: env!("CARGO_PKG_VERSION"),
        generated_at: now(),
        options: ManifestOptions {
            include_usage: options.include_usage,
            include_assistant: options.include_assistant,
            include_subagents: options.include_subagents,
            include_history: options.include_history,
            redacted: options.redact,
            max_message_chars: options.max_message_chars,
        },
        totals: totals(sessions),
        by_source,
        sessions: sessions
            .iter()
            .map(|session| SessionEntry {
                id: session.id.clone(),
                source: session.source.slug(),
                title: session.display_title(),
                project: session.project.clone(),
                created_at: session.started_at,
                updated_at: session.updated_at(),
                prompts: session.user_message_count(),
                messages: session.messages.len(),
            })
            .collect(),
    }
}

pub fn write(path: &Path, sessions: &[Session], options: &Options) -> io::Result<u64> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)?;
    }
    let file = File::create(path)?;
    let mut zip = ZipWriter::new(file);
    let entry = SimpleFileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .large_file(true);
    // Without this every entry carries the ZIP epoch of 1980.
    let (year, month, day, hour, minute, second) = time::civil(now());
    let entry = match zip::DateTime::from_date_and_time(year, month, day, hour, minute, second) {
        Ok(stamp) => entry.last_modified_time(stamp),
        Err(_) => entry,
    };

    let conversations: Vec<_> = sessions.iter().filter_map(session::to_export).collect();
    zip.start_file("conversations.json", entry)?;
    serde_json::to_writer(&mut zip, &conversations)?;

    let records: Vec<SessionRecord> = sessions
        .iter()
        .filter(|session| !session.stats.is_empty())
        .map(|session| {
            efficiency::to_record(
                &session.id,
                session.source.slug(),
                session.started_at,
                &session.stats,
            )
        })
        .collect();
    if !records.is_empty() {
        zip.start_file("efficiency.json", entry)?;
        serde_json::to_writer(
            &mut zip,
            &serde_json::json!({
                "format": "memory-pack-efficiency/1",
                "sessions": records,
            }),
        )?;
    }

    zip.start_file("memory-pack.json", entry)?;
    serde_json::to_writer_pretty(&mut zip, &build_manifest(sessions, options))?;

    zip.start_file("README.txt", entry)?;
    zip.write_all(READ_ME.as_bytes())?;

    zip.finish()?;
    Ok(std::fs::metadata(path)?.len())
}

/// Counts prompts a person actually typed, used for the run summary.
pub fn prompt_count(sessions: &[Session]) -> usize {
    sessions
        .iter()
        .flat_map(|session| session.messages.iter())
        .filter(|message| message.role == Role::User)
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Message;

    fn session(id: &str, source: Source, at: f64) -> Session {
        Session {
            id: id.into(),
            source,
            title: Some("Titled".into()),
            project: Some("/repo".into()),
            started_at: at,
            messages: vec![
                Message {
                    role: Role::User,
                    text: "ask".into(),
                    at,
                    model: None,
                },
                Message {
                    role: Role::Assistant,
                    text: "answer".into(),
                    at: at + 1.0,
                    model: None,
                },
            ],
            stats: crate::efficiency::SessionStats::default(),
        }
    }

    #[test]
    fn totals_span_every_session() {
        let sessions = vec![
            session("a", Source::ClaudeCode, 100.0),
            session("b", Source::Codex, 500.0),
        ];
        let totals = totals(&sessions);

        assert_eq!(totals.sessions, 2);
        assert_eq!(totals.prompts, 2);
        assert_eq!(totals.messages, 4);
        assert_eq!(totals.earliest, 100.0);
        assert_eq!(totals.latest, 501.0);
        assert_eq!(prompt_count(&sessions), 2);
        assert_eq!(totals_for(&sessions, Source::Codex).sessions, 1);
    }

    #[test]
    fn writes_a_readable_archive() {
        let directory =
            std::env::temp_dir().join(format!("memory-pack-test-{}", std::process::id()));
        let path = directory.join("archive.zip");
        let sessions = vec![session("claude-a", Source::ClaudeCode, 100.0)];
        let size = write(&path, &sessions, &Options::default()).unwrap();
        assert!(size > 0);

        let mut archive = zip::ZipArchive::new(File::open(&path).unwrap()).unwrap();
        let names: Vec<String> = archive.file_names().map(str::to_string).collect();
        assert!(names.contains(&"conversations.json".to_string()));
        assert!(names.contains(&"memory-pack.json".to_string()));
        assert!(names.contains(&"README.txt".to_string()));

        let mut body = String::new();
        io::Read::read_to_string(
            &mut archive.by_name("conversations.json").unwrap(),
            &mut body,
        )
        .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&body).unwrap();
        let conversation = &parsed[0];
        assert_eq!(conversation["title"], "Titled");
        assert_eq!(conversation["current_node"], "n000001");
        assert_eq!(
            conversation["mapping"]["n000000"]["message"]["content"]["parts"][0],
            "ask"
        );

        std::fs::remove_dir_all(&directory).ok();
    }
}
