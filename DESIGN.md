# ContextDaddy design contract

## Selected direction

Owner-directed StorageDaddy family fork: keep the A+C information architecture (live operations plus a policy ledger), but express it through StorageDaddy's warm black-and-mint visual language, rounded typography, fine outlines, and editorial Daddy doodles.

For the Usage landing surface, the owner initially selected **Focus Desk (direction A)** from three visual systems. The owner then specified CodeVetter Usage as the information-architecture reference, apart from ContextDaddy's colors and theme. The first scan presents both provider allowances and Devin's separate indexed source before the long unified history chart and breakdown. The owner subsequently selected **Decision Desk (direction A)** for skills and telemetry navigation: direct Telemetry access, task-first Skills, and secondary raw Evidence. Daddy art remains.

The general usage dashboard extends the same visual direction: metric/scale/group/range controls and model/project attribution belong to the unified chart, while session-level projects and recent sessions follow the one-page scroll and evidence-chapter grammar. Live OTEL has its own destination. This is a migration of capability and information hierarchy, not a transplant of CodeVetter's visual system.

## Thesis

ContextDaddy should feel unmistakably related to StorageDaddy while solving a different job. It is a friendly local instrument rather than a generic observability console: compact and precise, but human enough to make a dense subject approachable.

## System

- Pure black canvas with thin mint-outlined surfaces and minimal elevation, matching the StorageDaddy shell.
- Mint means measured/healthy; blue means derived; amber means partial/estimated; coral means failure or disabled.
- Rounded display typography, compact monospaced paths, and the same button geometry and secondary-text tint as StorageDaddy.
- A two-column native shell with four task destinations: Usage, Skills, Projects, OpenTelemetry. A secondary Files & diagnostics control opens raw Inventory and Diagnostics without making them peer destinations. Page headings carry the fuller explanation.
- Evidence badges accompany values rather than relying on color alone.
- The inherited Daddy doodle sheet is functional art: the context-cart hero explains the product, section scenes reinforce location, and the agent scene becomes the in-app family mark.

## Signature element

Friendly artwork and hard provenance coexist. Every operational number and policy decision still carries measured, derived, estimated, partial, or unavailable evidence; expanded skill rows explain the rule and provide invocation syntax.

The Skills page begins with an agent-scoped view of how skills run. Three clickable, exclusive invocation totals answer what is automatic, manual-only, or unavailable for discovery. A separate needs-review queue explicitly overlaps those statuses. The sharing strip shows whether skills are portable across all agents, several agents, or only one. Installed cache copies remain visible in rows without receiving an active-policy color.

The same destination has a Redundancy review mode rather than a sixth sidebar item. Its first scan is decision-oriented: exact-copy groups, same-name drift, likely purpose overlap, and duplicate file bytes. The default queue excludes cache-only groups, which remain available through a dedicated filter and summary count. Every row states confidence, evidence, affected agents, a keep candidate, and why no automatic deletion follows. Managed plugin caches are visibly different from owner-managed definitions, and an always-visible boundary explains that missing usage telemetry is not proof of non-use.

Project rows use the same progressive-disclosure grammar: a compact project summary expands into agent pressure cards and attributed local/inherited locations. The matching set is paginated in stable 12-row slices. Source inventory groups exposures by origin and opens text only through an explicit preview sheet.

Files & diagnostics begins with read-only configuration health. It deduplicates startup noise into root causes, distinguishes ignored file settings from broken MCP launchers, and exposes exact file/line evidence plus copyable single or all-issue remediation briefs and a coverage-aware rescan, without copying credential-bearing values or modifying configuration. Launch-time session flags are outside this file scan. A labelled configuration-issue count on the secondary control keeps unresolved health visible from every destination.

Usage follows CodeVetter's usage hierarchy while making Devin visible in the first scan: both provider allowances first, Devin's independent indexed panel second, unified local history third, then selected-agent detail. Allowance checks remain manual by default; an explicit switch enables a throttled check on opening Usage. Optional Codex reset-credit dates are labelled latest reported expiry, not guaranteed final expiry. Devin can be selected as a separate source in the local-history chart, without merged totals or invented cost. The direct OpenTelemetry destination has a fixed 24-hour window, a Codex/Claude switch, agent-specific connection status, and in-app breakdowns for tokens, models, tools, MCP, skills, time, and reliability. When the collector is reachable but Claude returns no verified metrics, a dedicated unavailable state replaces empty metric cards and navigates to separate Usage history. Claude shows only verified metrics supplied by the same collector; tool/API counts remain unavailable until a safe logs/trace adapter exists. The core workflow never requires an external dashboard. Bar lengths compare values only within one card; they never imply that overlapping duration categories sum to wall time.

The Skills redundancy mode and Codex Telemetry view lead with a short read-only review queue. Skill conflicts are ranked by runtime exposure and evidence; OTEL flags failed requests, compactions, and concentrated calls only as investigation signals. Every action keeps its source, window, confidence, and limitation visible. No insight claims that missing injections mean a skill was unused or that high call volume alone was inefficient.

Usage project grouping uses a separate session ledger with Codex thread-index working directories, Grok paths, and Claude's encoded project slugs. The chart buckets whole sessions by last activity and explicitly disclaims reconciliation with daily totals; it never fabricates daily project token allocation. Model-provider grouping uses a narrow model-name classifier and retains unknown aliases. Devin has the same provider control in its separate index, never in a summed cross-source total.

Copy all issues produces a structured handoff for an external coding agent, including every skill finding rather than only the three preview cards. The app never changes files itself. After agent work, Verify after changes rescans skill definitions: an issue is detector-cleared only when its original locations remain covered and no pair of those definitions still forms a finding. Missing locations or scan failure stay unverified. OTEL issue briefs explicitly require a comparable new window; a rolling counter dropping is not presented as proof of a fix.

## Primary risk

Dense operational information can become tiring or ambiguous. Progressive disclosure keeps the first scan compact; explanations and physical/logical paths appear only when a row is expanded.

## Interaction constraints

- Refresh is explicit and preserves the last valid inventory if a scan fails.
- Usage service, model, and range filters only affect data that supports those dimensions. Panels with a fixed 24-hour or account-level scope keep their own scope label rather than pretending to follow the filter.
- Local usage, provider allowance, and OTEL are separate ledgers; their numbers are never summed or treated as interchangeable. Local usage comes from bundled offline ccusage plus separately labelled Devin index buckets. Provider allowance makes authenticated provider calls only on explicit refresh or after the user enables a throttled automatic check.
- Search and policy filtering stay visible above the ledger.
- Redundancy search, evidence type, and agent scope stay visible above consolidation candidates; All agents is the default scope.
- Selecting an agent changes both summary counts and filters; policies from other agents remain visible for comparison.
- Project filters reset pagination and expansion; matching projects remain reachable through stable page slices. Source filters reset pagination and expansion so stale selection never points at hidden data.
- Long source groups paginate instead of silently truncating results.
- Each list destination has one vertical scroll surface. Headers, filters, results, and pagination remain reachable at the minimum window height rather than competing for a fixed-height inner list.
- Toolbars, policy grids, file rows, and telemetry panels reflow at the minimum supported window width instead of shrinking labels into clipped fragments.
- Restored windows are constrained to the current display's visible frame, including when moving between displays with different usable heights.
- No control implies that ContextDaddy can change agent policy in v1.
- Empty, partial, and unavailable states are first-class visual states.
