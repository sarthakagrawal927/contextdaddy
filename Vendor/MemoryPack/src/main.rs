//! memory-pack — turn local Claude Code and Codex sessions into one archive
//! that Memory Map can read.

mod archive;
mod claude;
mod codex;
mod efficiency;
mod history;
mod input;
mod options;
mod session;
mod source;
mod text;
mod time;

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, ValueEnum};

use options::{Collection, Options};
use session::{Session, Source};
use source::SourceFile;

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum SourceArg {
    All,
    Claude,
    Codex,
}

#[derive(Parser)]
#[command(
    name = "memory-pack",
    version,
    about = "Pack local Claude Code and Codex sessions into a Memory Map archive",
    long_about = "Reads the transcripts Claude Code and Codex already keep on this machine and \
writes one ZIP holding your prompts and the assistant's replies. Tool calls, tool output, \
reasoning traces, and file contents are left behind. Upload the ZIP to Memory Map without \
unzipping it."
)]
struct Cli {
    /// Where to write the archive.
    #[arg(short, long, value_name = "PATH")]
    output: Option<PathBuf>,

    /// Which agent's sessions to read.
    #[arg(long, value_enum, default_value_t = SourceArg::All)]
    source: SourceArg,

    /// Claude Code home directory.
    #[arg(long, value_name = "PATH")]
    claude_dir: Option<PathBuf>,

    /// Codex home directory.
    #[arg(long, value_name = "PATH")]
    codex_dir: Option<PathBuf>,

    /// Only pack sessions last active on or after this date (YYYY-MM-DD).
    #[arg(long, value_name = "DATE")]
    since: Option<String>,

    /// Pack only your prompts, leaving out the assistant's replies.
    #[arg(long)]
    no_assistant: bool,

    /// Leave credential-shaped tokens unmasked.
    #[arg(long)]
    no_redact: bool,

    /// Also pack transcripts of subagents your sessions spawned.
    #[arg(long)]
    include_subagents: bool,

    /// Truncate any single message longer than this many characters.
    #[arg(long, value_name = "N")]
    max_message_chars: Option<usize>,

    /// Report what would be packed without writing the archive.
    #[arg(long)]
    dry_run: bool,

    /// Print one line per session.
    #[arg(long)]
    list: bool,

    /// Pack only sessions with a surviving transcript, ignoring the prompt
    /// history both CLIs keep for sessions they have since pruned.
    #[arg(long)]
    no_history: bool,

    /// Leave out the token and tool accounting that explains why sessions were
    /// expensive. The report's efficiency findings need it.
    #[arg(long)]
    no_usage: bool,

    /// Include only transcript files whose filesystem mtime is strictly before this epoch.
    #[arg(long, value_name = "EPOCH_SECONDS", requires = "no_history")]
    modified_before: Option<f64>,

    /// Write a private aggregate receipt after a successful archive export.
    #[arg(long, value_name = "PATH")]
    receipt: Option<PathBuf>,
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// Parses `YYYY-MM-DD` into the epoch second its day begins.
fn parse_since(date: &str) -> Result<f64, String> {
    time::epoch_seconds(&format!("{date}T00:00:00Z"))
        .ok_or_else(|| format!("--since expects a YYYY-MM-DD date, got `{date}`"))
}

fn plural(count: usize, singular: &str) -> String {
    if count == 1 {
        format!("{count} {singular}")
    } else {
        format!("{count} {singular}s")
    }
}

fn describe_size(bytes: u64) -> String {
    const MEGABYTE: f64 = 1_048_576.0;
    let megabytes = bytes as f64 / MEGABYTE;
    if megabytes < 0.1 {
        format!("{:.0} KB", bytes as f64 / 1024.0)
    } else {
        format!("{megabytes:.1} MB")
    }
}

fn default_output(sessions: &[Session]) -> PathBuf {
    let latest = archive::totals(sessions).latest;
    PathBuf::from(format!("memory-pack-{}.zip", time::date_stamp(latest)))
}

fn report_sources(sessions: &[Session]) {
    for source in [Source::ClaudeCode, Source::Codex] {
        let counts = archive::totals_for(sessions, source);
        if counts.sessions == 0 {
            continue;
        }
        println!(
            "  {:<12} {:>4} sessions  {:>6} prompts  {:>6} messages",
            source.label(),
            counts.sessions,
            counts.prompts,
            counts.messages
        );
    }
}

fn report_sessions(sessions: &[Session]) {
    for session in sessions {
        println!(
            "  {}  {:<11} {:>3}p  {}",
            time::date_stamp(session.updated_at()),
            session.source.slug(),
            session.user_message_count(),
            session.display_title()
        );
    }
}

#[derive(serde::Serialize)]
struct Receipt {
    format: &'static str,
    #[serde(rename = "sourceFiles")]
    source_files: usize,
    #[serde(rename = "sourceBytes")]
    source_bytes: u64,
    sessions: usize,
    prompts: usize,
    messages: usize,
    #[serde(rename = "skippedFiles")]
    skipped_files: usize,
    sources: Vec<SourceFile>,
}

fn write_receipt(
    path: &PathBuf,
    collection: &Collection,
    sessions: &[Session],
) -> Result<(), String> {
    let totals = archive::totals(sessions);
    let session_ids: std::collections::HashSet<&str> =
        sessions.iter().map(|session| session.id.as_str()).collect();
    let sources: Vec<SourceFile> = collection
        .sources
        .iter()
        .filter(|source| session_ids.contains(source.session_id.as_str()))
        .cloned()
        .collect();
    let source_bytes = sources.iter().map(|source| source.size.max(0) as u64).sum();
    let receipt = Receipt {
        format: "memory-pack-receipt/1",
        source_files: sources.len(),
        source_bytes,
        sessions: totals.sessions,
        prompts: totals.prompts,
        messages: totals.messages,
        skipped_files: collection.skipped_files,
        sources,
    };
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| format!("could not create receipt: {error}"))?;
    serde_json::to_writer_pretty(&mut file, &receipt)
        .map_err(|error| format!("could not write receipt: {error}"))?;
    file.write_all(b"\n")
        .map_err(|error| format!("could not finish receipt: {error}"))?;
    file.sync_all()
        .map_err(|error| format!("could not sync receipt: {error}"))?;
    Ok(())
}

fn run(cli: Cli) -> Result<(), String> {
    let home = home_dir();
    let options = Options {
        include_subagents: cli.include_subagents,
        include_assistant: !cli.no_assistant,
        redact: !cli.no_redact,
        max_message_chars: cli.max_message_chars,
        since: cli.since.as_deref().map(parse_since).transpose()?,
        include_history: !cli.no_history,
        include_usage: !cli.no_usage,
        modified_before: cli.modified_before,
    };

    let claude_dir = cli
        .claude_dir
        .or_else(|| home.as_ref().map(|home| home.join(".claude")))
        .ok_or("Could not find a home directory. Pass --claude-dir and --codex-dir.")?;
    let codex_dir = cli
        .codex_dir
        .or_else(|| home.as_ref().map(|home| home.join(".codex")))
        .ok_or("Could not find a home directory. Pass --claude-dir and --codex-dir.")?;

    let mut sessions = Vec::new();
    let mut collection = Collection::default();
    if cli.source != SourceArg::Codex {
        eprintln!("Reading Claude Code sessions from {}", claude_dir.display());
        let collected = claude::collect_checked(&claude_dir, &options)?;
        collection.source_files += collected.source_files;
        collection.source_bytes += collected.source_bytes;
        collection.skipped_files += collected.skipped_files;
        collection.sources.extend(collected.sources);
        sessions.extend(collected.sessions);
    }
    if cli.source != SourceArg::Claude {
        eprintln!("Reading Codex sessions from {}", codex_dir.display());
        let collected = codex::collect_checked(&codex_dir, &options)?;
        collection.source_files += collected.source_files;
        collection.source_bytes += collected.source_bytes;
        collection.skipped_files += collected.skipped_files;
        collection.sources.extend(collected.sources);
        sessions.extend(collected.sessions);
    }

    if options.include_history {
        let mut recovered = (0usize, 0usize);
        if cli.source != SourceArg::Codex {
            let counts = history::merge(
                &mut sessions,
                &claude_dir,
                Source::ClaudeCode,
                &HashMap::new(),
                &options,
            );
            recovered = (recovered.0 + counts.0, recovered.1 + counts.1);
        }
        if cli.source != SourceArg::Claude {
            // The thread index outlives the rollouts, so it can still name a
            // session whose transcript is gone.
            let titles = codex::read_titles(&codex_dir);
            let counts =
                history::merge(&mut sessions, &codex_dir, Source::Codex, &titles, &options);
            recovered = (recovered.0 + counts.0, recovered.1 + counts.1);
        }
        if recovered.0 > 0 {
            eprintln!(
                "Recovered {} from prompt history, rebuilding {}",
                plural(recovered.0, "prompt"),
                plural(recovered.1, "pruned session")
            );
        }
    }

    if let Some(since) = options.since {
        sessions.retain(|session| session.updated_at() >= since);
    }
    sessions.sort_by(|left, right| left.started_at.total_cmp(&right.started_at));

    if sessions.is_empty() {
        if let Some(receipt) = &cli.receipt {
            write_receipt(receipt, &collection, &sessions)?;
            println!("No sessions matched; wrote receipt.");
            return Ok(());
        }
        return Err(
            "No sessions were found. Check --claude-dir and --codex-dir, or widen --since.".into(),
        );
    }

    let totals = archive::totals(&sessions);
    println!(
        "\nFound {} spanning {} to {}",
        plural(totals.sessions, "session"),
        time::date_stamp(totals.earliest),
        time::date_stamp(totals.latest)
    );
    report_sources(&sessions);
    if cli.list {
        report_sessions(&sessions);
    }

    if cli.dry_run {
        println!("\nDry run: nothing was written.");
        return Ok(());
    }

    let output = cli.output.unwrap_or_else(|| default_output(&sessions));
    let size = archive::write(&output, &sessions, &options)
        .map_err(|error| format!("Could not write {}: {error}", output.display()))?;

    println!(
        "\nWrote {} ({}, {})",
        output.display(),
        describe_size(size),
        plural(archive::prompt_count(&sessions), "prompt")
    );
    if !options.redact {
        println!("Secrets were not masked: this archive was built with --no-redact.");
    }
    println!("Upload it to Memory Map without unzipping it.");
    if let Some(receipt) = &cli.receipt {
        write_receipt(receipt, &collection, &sessions)?;
    }
    Ok(())
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("memory-pack: {message}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn verifies_the_command_line_definition() {
        use clap::CommandFactory;
        Cli::command().debug_assert();
    }

    #[test]
    fn reads_a_since_date() {
        assert_eq!(
            parse_since("2026-08-29").unwrap(),
            time::epoch_seconds("2026-08-29T00:00:00Z").unwrap()
        );
        assert!(parse_since("last tuesday").is_err());
        assert!(parse_since("2026-13-01").is_err());
    }

    #[test]
    fn describes_counts_and_sizes_for_humans() {
        assert_eq!(plural(1, "session"), "1 session");
        assert_eq!(plural(2, "session"), "2 sessions");
        assert_eq!(describe_size(2048), "2 KB");
        assert_eq!(describe_size(5_242_880), "5.0 MB");
    }

    #[test]
    fn writes_private_zero_session_receipt() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("memory-pack-receipt-{stamp}.json"));
        write_receipt(&path, &Collection::default(), &[]).unwrap();
        let value: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(value["format"], "memory-pack-receipt/1");
        assert_eq!(value["sourceFiles"], 0);
        assert_eq!(value["sessions"], 0);
        assert_eq!(value["prompts"], 0);
        assert_eq!(value["messages"], 0);
        assert_eq!(value["skippedFiles"], 0);
        assert_eq!(value["sources"], serde_json::json!([]));
        #[cfg(unix)]
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn receipt_sources_keep_only_files_represented_in_final_sessions() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let temporary = std::env::temp_dir()
            .to_string_lossy()
            .replace("/var/", "/private/var/");
        let root = PathBuf::from(temporary).join(format!("memory-pack-source-manifest-{stamp}"));
        let claude_dir = root.join("claude");
        let codex_dir = root.join("codex");
        std::fs::create_dir_all(claude_dir.join("projects/demo")).unwrap();
        std::fs::create_dir_all(codex_dir.join("sessions/2026/08/29")).unwrap();
        std::fs::write(
            claude_dir.join("projects/demo/valid.jsonl"),
            r#"{"type":"user","promptSource":"typed","message":{"content":"claude ask"},"timestamp":"2026-08-29T16:03:47.000Z","sessionId":"claude-thread"}"#,
        )
        .unwrap();
        std::fs::write(
            codex_dir.join("sessions/2026/08/29/valid.jsonl"),
            r#"{"timestamp":"2026-08-29T16:03:47.000Z","type":"session_meta","payload":{"id":"codex-thread","cwd":"/repo"}}
{"timestamp":"2026-08-29T16:03:47.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"codex ask"}]}}"#,
        )
        .unwrap();
        std::fs::write(
            claude_dir.join("projects/demo/empty.jsonl"),
            b"not a conversation",
        )
        .unwrap();
        std::fs::write(
            codex_dir.join("sessions/2026/08/29/unsupported.txt"),
            b"ignored",
        )
        .unwrap();

        let options = Options {
            include_history: false,
            ..Options::default()
        };
        let claude = claude::collect_checked(&claude_dir, &options).unwrap();
        let codex = codex::collect_checked(&codex_dir, &options).unwrap();
        let mut collection = Collection::default();
        collection.sources.extend(claude.sources);
        collection.sources.extend(codex.sources);
        collection.source_files = collection.sources.len();
        collection.source_bytes = collection
            .sources
            .iter()
            .map(|source| source.size.max(0) as u64)
            .sum();
        let mut sessions = claude.sessions;
        sessions.extend(codex.sessions);

        let receipt = root.join("receipt.json");
        write_receipt(&receipt, &collection, &sessions).unwrap();
        let value: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&receipt).unwrap()).unwrap();
        assert_eq!(value["sourceFiles"], 2);
        assert_eq!(value["sources"].as_array().unwrap().len(), 2);
        for source in value["sources"].as_array().unwrap() {
            assert!(source["path"].as_str().unwrap().starts_with('/'));
            assert!(source["device"].as_u64().is_some());
            assert!(source["inode"].as_u64().is_some());
            assert!(source["size"].as_i64().unwrap() > 0);
            for field in [
                "modifiedSeconds",
                "modifiedNanoseconds",
                "changedSeconds",
                "changedNanoseconds",
            ] {
                assert!(source[field].as_i64().is_some(), "missing {field}");
            }
        }
        assert_eq!(value["sources"][0]["session_id"], serde_json::Value::Null);

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn receipt_has_no_sources_when_no_file_has_eligible_messages() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let temporary = std::env::temp_dir()
            .to_string_lossy()
            .replace("/var/", "/private/var/");
        let root = PathBuf::from(temporary).join(format!("memory-pack-no-sources-{stamp}"));
        let claude_dir = root.join("claude/projects/demo");
        std::fs::create_dir_all(&claude_dir).unwrap();
        std::fs::write(claude_dir.join("empty.jsonl"), b"not json\n").unwrap();
        let options = Options {
            include_history: false,
            ..Options::default()
        };
        let collection = claude::collect_checked(root.join("claude").as_path(), &options).unwrap();
        assert!(collection.sessions.is_empty());
        assert!(collection.sources.is_empty());

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn names_the_archive_after_the_newest_session() {
        let sessions = vec![Session {
            id: "claude-a".into(),
            source: Source::ClaudeCode,
            title: None,
            project: None,
            started_at: 1_788_019_427.0,
            messages: vec![session::Message {
                role: session::Role::User,
                text: "hi".into(),
                at: 1_788_019_427.0,
                model: None,
            }],
            stats: crate::efficiency::SessionStats::default(),
        }];
        assert_eq!(
            default_output(&sessions),
            PathBuf::from("memory-pack-2026-08-29.zip")
        );
    }
}
