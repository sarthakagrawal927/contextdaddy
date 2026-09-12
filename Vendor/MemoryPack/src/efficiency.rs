//! Per-session efficiency accounting.
//!
//! Both CLIs record how many tokens every turn consumed, and both record every
//! tool call. None of that is conversation, so the archive drops it — but it is
//! what explains why a session was expensive. This module collects a compact
//! record per session: token totals, tool and command frequencies, and the
//! three kinds of waste that can be proven from a transcript rather than
//! guessed at (repeated identical calls, failed calls, and the volume of tool
//! output fed back into context).

use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};

use serde::Serialize;

/// How many entries of a frequency table to keep per session.
const TOP_N: usize = 8;

#[derive(Clone, Copy, Debug, Default, Serialize)]
pub struct Tokens {
    pub input: u64,
    pub output: u64,
    /// Context re-read on a turn. This dominates every other number, because
    /// each turn re-reads the whole accumulated transcript.
    pub cache_read: u64,
    pub cache_write: u64,
    pub reasoning: u64,
}

impl Tokens {
    fn add(&mut self, other: Tokens) {
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_write += other.cache_write;
        self.reasoning += other.reasoning;
    }
}

#[derive(Clone, Debug, Default)]
pub struct SessionStats {
    /// Assistant turns, the unit context re-reads scale with.
    pub turns: u64,
    pub tokens: Tokens,
    pub tool_calls: u64,
    /// Calls whose tool and arguments exactly repeat an earlier call in the
    /// same session: work redone, and its output re-read from then on.
    pub repeated_calls: u64,
    pub failed_calls: u64,
    /// Bytes of tool output handed back to the model. Once returned, this is
    /// re-read by every later turn in the session.
    pub tool_result_bytes: u64,
    /// Calls that read a whole file rather than a slice of one.
    pub whole_file_reads: u64,
    pub tools: HashMap<String, u64>,
    pub commands: HashMap<String, u64>,
    seen_calls: HashMap<u64, ()>,
}

/// Shell verbs that pull an entire file into context.
const WHOLE_FILE_COMMANDS: &[&str] = &["cat", "less", "more"];

/// Tools whose whole purpose is to be called again with the same arguments.
/// Counting their repeats as redundant work would report polling as waste.
const POLLING_TOOLS: &[&str] = &[
    "wait",
    "wait_agent",
    "list_agents",
    "sleep",
    "TaskOutput",
    "Monitor",
];

fn fingerprint(name: &str, arguments: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    name.hash(&mut hasher);
    arguments.hash(&mut hasher);
    hasher.finish()
}

impl SessionStats {
    pub fn record_turn(&mut self, tokens: Tokens) {
        self.turns += 1;
        self.tokens.add(tokens);
    }

    /// Counts a turn without token detail, for a reader whose usage arrives
    /// as a running total rather than per turn.
    pub fn count_turn(&mut self) {
        self.turns += 1;
    }

    /// Replaces the running total with a cumulative one. Codex reports usage
    /// as a running total per session rather than per turn.
    pub fn set_cumulative_tokens(&mut self, tokens: Tokens) {
        self.tokens = tokens;
    }

    pub fn record_tool(&mut self, name: &str, arguments: &str) {
        self.tool_calls += 1;
        *self.tools.entry(name.to_string()).or_default() += 1;
        let repeated = self
            .seen_calls
            .insert(fingerprint(name, arguments), ())
            .is_some();
        if repeated && !POLLING_TOOLS.contains(&name) {
            self.repeated_calls += 1;
        }
        if name == "Read" && !arguments.contains("\"limit\"") && !arguments.contains("\"offset\"") {
            self.whole_file_reads += 1;
        }
    }

    pub fn record_command(&mut self, command: &str) {
        if let Some(verb) = command_verb(command) {
            if WHOLE_FILE_COMMANDS.contains(&verb.as_str()) {
                self.whole_file_reads += 1;
            }
            *self.commands.entry(verb).or_default() += 1;
        }
    }

    pub fn record_result(&mut self, bytes: u64, failed: bool) {
        self.tool_result_bytes += bytes;
        if failed {
            self.failed_calls += 1;
        }
    }

    pub fn merge(&mut self, other: &SessionStats) {
        self.turns += other.turns;
        self.tokens.add(other.tokens);
        self.tool_calls += other.tool_calls;
        self.repeated_calls += other.repeated_calls;
        self.failed_calls += other.failed_calls;
        self.tool_result_bytes += other.tool_result_bytes;
        self.whole_file_reads += other.whole_file_reads;
        for (name, count) in &other.tools {
            *self.tools.entry(name.clone()).or_default() += count;
        }
        for (name, count) in &other.commands {
            *self.commands.entry(name.clone()).or_default() += count;
        }
    }

    pub fn is_empty(&self) -> bool {
        self.turns == 0 && self.tool_calls == 0 && self.tokens.cache_read == 0
    }
}

/// The leading verb of a shell command, with a subcommand when the tool is one
/// whose subcommands mean different things (`git diff` is not `git add`).
pub fn command_verb(command: &str) -> Option<String> {
    let mut rest = command.trim();
    // Step over `cd x &&` and `FOO=bar` prefixes to reach the real verb.
    loop {
        let trimmed = rest.trim_start();
        let head = trimmed.split_whitespace().next()?;
        if head.contains('=') && !head.contains('/') {
            rest = &trimmed[head.len()..];
            continue;
        }
        if head == "cd" {
            match trimmed.find("&&") {
                Some(position) => {
                    rest = &trimmed[position + 2..];
                    continue;
                }
                None => return Some("cd".to_string()),
            }
        }
        rest = trimmed;
        break;
    }

    let mut words = rest.split_whitespace();
    let head = words.next()?;
    let head = head.rsplit('/').next().unwrap_or(head);
    if head.is_empty() || head.starts_with('-') {
        return None;
    }

    const SUBCOMMAND_TOOLS: &[&str] = &[
        "git", "pnpm", "npm", "npx", "cargo", "gh", "docker", "wrangler", "yarn", "brew", "kubectl",
    ];
    if SUBCOMMAND_TOOLS.contains(&head) {
        if let Some(sub) = words.next() {
            if !sub.starts_with('-') && sub.chars().all(|c| c.is_alphanumeric() || c == '-') {
                return Some(format!("{head} {sub}"));
            }
        }
    }
    Some(head.to_string())
}

fn top_entries(table: &HashMap<String, u64>) -> Vec<(String, u64)> {
    let mut entries: Vec<(String, u64)> = table
        .iter()
        .map(|(name, count)| (name.clone(), *count))
        .collect();
    // Count descending, then name, so the output is deterministic.
    entries.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    entries.truncate(TOP_N);
    entries
}

/// One session's efficiency record, as written to the archive.
#[derive(Serialize)]
pub struct SessionRecord {
    pub id: String,
    pub source: &'static str,
    pub started_at: f64,
    pub turns: u64,
    pub tokens: Tokens,
    pub tool_calls: u64,
    pub repeated_calls: u64,
    pub failed_calls: u64,
    pub tool_result_bytes: u64,
    pub whole_file_reads: u64,
    pub top_tools: Vec<(String, u64)>,
    pub top_commands: Vec<(String, u64)>,
}

pub fn to_record(
    id: &str,
    source: &'static str,
    started_at: f64,
    stats: &SessionStats,
) -> SessionRecord {
    SessionRecord {
        id: id.to_string(),
        source,
        started_at,
        turns: stats.turns,
        tokens: stats.tokens,
        tool_calls: stats.tool_calls,
        repeated_calls: stats.repeated_calls,
        failed_calls: stats.failed_calls,
        tool_result_bytes: stats.tool_result_bytes,
        whole_file_reads: stats.whole_file_reads,
        top_tools: top_entries(&stats.tools),
        top_commands: top_entries(&stats.commands),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_verb_through_prefixes_and_paths() {
        assert_eq!(command_verb("grep -rn foo src"), Some("grep".into()));
        assert_eq!(
            command_verb("  /usr/bin/sed -i s/a/b/ f"),
            Some("sed".into())
        );
        assert_eq!(
            command_verb("cd /repo && git diff --stat"),
            Some("git diff".into())
        );
        assert_eq!(
            command_verb("FOO=1 BAR=2 cargo test --all"),
            Some("cargo test".into())
        );
        assert_eq!(command_verb("cd /repo"), Some("cd".into()));
        assert_eq!(command_verb("git -C /repo status"), Some("git".into()));
        assert_eq!(command_verb(""), None);
        assert_eq!(command_verb("--flag only"), None);
    }

    #[test]
    fn counts_a_repeated_call_once_per_repeat() {
        let mut stats = SessionStats::default();
        stats.record_tool("Bash", "{\"command\":\"ls\"}");
        stats.record_tool("Bash", "{\"command\":\"ls\"}");
        stats.record_tool("Bash", "{\"command\":\"ls\"}");
        stats.record_tool("Bash", "{\"command\":\"pwd\"}");

        assert_eq!(stats.tool_calls, 4);
        assert_eq!(stats.repeated_calls, 2);
        assert_eq!(stats.tools["Bash"], 4);
    }

    #[test]
    fn does_not_count_polling_as_redundant_work() {
        let mut stats = SessionStats::default();
        for _ in 0..5 {
            stats.record_tool("wait", "{\"ms\":1000}");
        }
        stats.record_tool("exec", "{\"cmd\":\"ls\"}");
        stats.record_tool("exec", "{\"cmd\":\"ls\"}");

        assert_eq!(stats.tool_calls, 7);
        assert_eq!(stats.repeated_calls, 1, "only the repeated exec counts");
    }

    #[test]
    fn notices_reads_that_pull_a_whole_file() {
        let mut stats = SessionStats::default();
        stats.record_tool("Read", "{\"file_path\":\"a.rs\"}");
        stats.record_tool("Read", "{\"file_path\":\"b.rs\",\"limit\":50}");
        stats.record_command("cat big.log");
        stats.record_command("grep needle big.log");

        assert_eq!(stats.whole_file_reads, 2);
        assert_eq!(stats.commands["cat"], 1);
        assert_eq!(stats.commands["grep"], 1);
    }

    #[test]
    fn keeps_only_the_busiest_entries_deterministically() {
        let mut stats = SessionStats::default();
        for index in 0..12 {
            for _ in 0..=index {
                stats.record_command(&format!("tool{index:02}"));
            }
        }
        let record = to_record("s", "claude-code", 1.0, &stats);
        assert_eq!(record.top_commands.len(), TOP_N);
        assert_eq!(record.top_commands[0].0, "tool11");
        assert!(record.top_commands[0].1 >= record.top_commands[1].1);
    }

    #[test]
    fn merges_two_halves_of_one_session() {
        let mut left = SessionStats::default();
        left.record_turn(Tokens {
            output: 10,
            cache_read: 100,
            ..Tokens::default()
        });
        left.record_command("git status");
        let mut right = SessionStats::default();
        right.record_turn(Tokens {
            output: 5,
            cache_read: 400,
            ..Tokens::default()
        });
        right.record_command("git status");
        right.record_result(2048, true);

        left.merge(&right);
        assert_eq!(left.turns, 2);
        assert_eq!(left.tokens.output, 15);
        assert_eq!(left.tokens.cache_read, 500);
        assert_eq!(left.commands["git status"], 2);
        assert_eq!(left.failed_calls, 1);
        assert_eq!(left.tool_result_bytes, 2048);
        assert!(!left.is_empty());
        assert!(SessionStats::default().is_empty());
    }
}
