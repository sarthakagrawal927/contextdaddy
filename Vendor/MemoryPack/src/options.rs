//! Packing options shared by both readers.

use crate::session::Session;
use crate::source::SourceFile;

#[derive(Clone, Debug)]
pub struct Options {
    /// Include the transcripts of subagents the main session spawned.
    pub include_subagents: bool,
    /// Include assistant prose. Prompts are always included.
    pub include_assistant: bool,
    /// Mask credential-shaped tokens before anything is written.
    pub redact: bool,
    /// Optional per-message character cap.
    pub max_message_chars: Option<usize>,
    /// Drop sessions whose last message predates this epoch second.
    pub since: Option<f64>,
    /// Merge the prompt histories both CLIs keep outside their transcripts.
    pub include_history: bool,
    /// Collect token and tool accounting so the report can explain cost.
    pub include_usage: bool,
    /// Include transcript files whose filesystem mtime is strictly before this epoch.
    pub modified_before: Option<f64>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            include_subagents: false,
            include_assistant: true,
            redact: true,
            max_message_chars: None,
            since: None,
            include_history: true,
            include_usage: true,
            modified_before: None,
        }
    }
}

#[derive(Default)]
pub struct Collection {
    pub sessions: Vec<Session>,
    pub source_files: usize,
    pub source_bytes: u64,
    pub skipped_files: usize,
    pub sources: Vec<SourceFile>,
}
