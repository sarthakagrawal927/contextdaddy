//! The neutral session model both readers produce, and its rendering into the
//! ChatGPT export shape the Memory Map worker already knows how to parse.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::efficiency::SessionStats;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    User,
    Assistant,
}

impl Role {
    fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Source {
    ClaudeCode,
    Codex,
}

impl Source {
    pub fn slug(self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude-code",
            Self::Codex => "codex",
        }
    }

    /// Prefix for conversation ids, keeping the two agents' session ids apart.
    pub fn id_prefix(self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude",
            Self::Codex => "codex",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::ClaudeCode => "Claude Code",
            Self::Codex => "Codex",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Message {
    pub role: Role,
    pub text: String,
    pub at: f64,
    pub model: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Session {
    pub id: String,
    pub source: Source,
    pub title: Option<String>,
    pub project: Option<String>,
    pub started_at: f64,
    pub messages: Vec<Message>,
    /// Token and tool accounting, kept out of the conversation itself.
    pub stats: SessionStats,
}

impl Session {
    pub fn updated_at(&self) -> f64 {
        self.messages
            .last()
            .map_or(self.started_at, |message| message.at)
    }

    pub fn user_message_count(&self) -> usize {
        self.messages
            .iter()
            .filter(|message| message.role == Role::User)
            .count()
    }

    /// A title the report can show: the recorded one when the agent captured
    /// it, otherwise the opening prompt clipped to a headline.
    pub fn display_title(&self) -> String {
        if let Some(title) = self
            .title
            .as_ref()
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
        {
            return title.to_string();
        }
        let opening = self
            .messages
            .iter()
            .find(|message| message.role == Role::User)
            .map(|message| message.text.as_str())
            .unwrap_or_default();
        let headline: String = opening
            .lines()
            .find(|line| !line.trim().is_empty())
            .unwrap_or_default()
            .trim()
            .chars()
            .take(72)
            .collect();
        if headline.is_empty() {
            format!("{} session", self.source.label())
        } else if opening.chars().count() > headline.chars().count() {
            format!("{headline}…")
        } else {
            headline
        }
    }

    /// The most recent model that actually answered. Sessions abandoned before
    /// a reply have none, and naming the agent here would invent a model the
    /// report would then chart.
    fn model_slug(&self) -> Option<String> {
        self.messages
            .iter()
            .rev()
            .find_map(|message| message.model.clone())
    }
}

#[derive(Serialize)]
struct Author {
    role: &'static str,
}

#[derive(Serialize)]
struct Content {
    content_type: &'static str,
    parts: [String; 1],
}

#[derive(Serialize)]
struct Metadata {
    #[serde(skip_serializing_if = "Option::is_none")]
    model_slug: Option<String>,
}

#[derive(Serialize)]
struct ExportMessage {
    id: String,
    author: Author,
    create_time: f64,
    content: Content,
    metadata: Metadata,
}

#[derive(Serialize)]
struct ExportNode {
    id: String,
    parent: Option<String>,
    message: Option<ExportMessage>,
}

/// One conversation in the shape `normalizeConversation` reads: a `mapping` of
/// nodes chained by `parent`, walked backwards from `current_node`.
#[derive(Serialize)]
pub struct ExportConversation {
    id: String,
    title: String,
    create_time: f64,
    update_time: f64,
    current_node: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    default_model_slug: Option<String>,
    mapping: BTreeMap<String, ExportNode>,
    /// Provenance for anyone reading the archive directly. The web worker
    /// ignores fields it does not know.
    memory_pack: Provenance,
}

#[derive(Serialize)]
struct Provenance {
    source: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    project: Option<String>,
}

/// Node keys are zero padded so the map's natural order stays chronological,
/// which is the order the reader's fallback path relies on.
fn node_key(index: usize) -> String {
    format!("n{index:06}")
}

pub fn to_export(session: &Session) -> Option<ExportConversation> {
    if session.messages.is_empty() {
        return None;
    }

    let model_slug = session.model_slug();
    let mut mapping = BTreeMap::new();
    let mut previous: Option<String> = None;
    for (index, message) in session.messages.iter().enumerate() {
        let key = node_key(index);
        mapping.insert(
            key.clone(),
            ExportNode {
                id: key.clone(),
                parent: previous.clone(),
                message: Some(ExportMessage {
                    id: format!("{}-{key}", session.id),
                    author: Author {
                        role: message.role.as_str(),
                    },
                    create_time: message.at,
                    content: Content {
                        content_type: "text",
                        parts: [message.text.clone()],
                    },
                    metadata: Metadata {
                        model_slug: message.model.clone(),
                    },
                }),
            },
        );
        previous = Some(key);
    }

    Some(ExportConversation {
        id: session.id.clone(),
        title: session.display_title(),
        create_time: session.started_at,
        update_time: session.updated_at(),
        current_node: node_key(session.messages.len() - 1),
        default_model_slug: model_slug,
        mapping,
        memory_pack: Provenance {
            source: session.source.slug(),
            project: session.project.clone(),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(role: Role, text: &str, at: f64) -> Message {
        Message {
            role,
            text: text.to_string(),
            at,
            model: None,
        }
    }

    fn session(messages: Vec<Message>) -> Session {
        Session {
            id: "claude-1".into(),
            source: Source::ClaudeCode,
            title: None,
            project: Some("fleet".into()),
            started_at: 100.0,
            messages,
            stats: crate::efficiency::SessionStats::default(),
        }
    }

    #[test]
    fn chains_nodes_so_the_reader_can_walk_them_backwards() {
        let session = session(vec![
            message(Role::User, "first", 100.0),
            message(Role::Assistant, "second", 101.0),
            message(Role::User, "third", 102.0),
        ]);
        let export = to_export(&session).unwrap();

        assert_eq!(export.current_node, "n000002");
        assert_eq!(export.mapping.len(), 3);
        assert_eq!(export.mapping["n000000"].parent, None);
        assert_eq!(export.mapping["n000001"].parent.as_deref(), Some("n000000"));
        assert_eq!(export.mapping["n000002"].parent.as_deref(), Some("n000001"));
        assert_eq!(export.update_time, 102.0);

        // Natural map order is chronological, which the fallback path needs.
        let order: Vec<_> = export.mapping.keys().cloned().collect();
        assert_eq!(order, vec!["n000000", "n000001", "n000002"]);
    }

    #[test]
    fn drops_a_session_with_no_messages() {
        assert!(to_export(&session(vec![])).is_none());
    }

    #[test]
    fn falls_back_to_the_opening_prompt_for_a_title() {
        let session = session(vec![message(
            Role::User,
            "Pack my sessions\nand upload",
            100.0,
        )]);
        assert_eq!(session.display_title(), "Pack my sessions…");

        let mut titled = session.clone();
        titled.title = Some("  Session export  ".into());
        assert_eq!(titled.display_title(), "Session export");

        let mut blank = session.clone();
        blank.messages = vec![message(Role::Assistant, "hello", 100.0)];
        assert_eq!(blank.display_title(), "Claude Code session");
    }

    #[test]
    fn prefers_the_most_recent_model_slug() {
        let mut answered = session(vec![
            message(Role::Assistant, "a", 100.0),
            message(Role::Assistant, "b", 101.0),
        ]);
        answered.messages[0].model = Some("old-model".into());
        answered.messages[1].model = Some("new-model".into());
        assert_eq!(
            to_export(&answered).unwrap().default_model_slug.as_deref(),
            Some("new-model")
        );

        let bare = session(vec![message(Role::User, "x", 1.0)]);
        assert_eq!(to_export(&bare).unwrap().default_model_slug, None);
    }
}
