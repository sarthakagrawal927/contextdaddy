# ContextDaddy product contract

## Purpose

ContextDaddy helps developers who use multiple coding agents understand and govern what each agent can see, invoke, and consume by combining bounded local skill/context discovery with redacted, provenance-aware run telemetry.

## Audience and job

The primary user is a developer running Codex, Claude, Cursor, Devin, or Grok on a Mac. They need to diagnose a live agent's consumption and audit skill invocation policy without manually tracing symlinks, frontmatter, runtime-specific config, and telemetry dashboards.

## Product promises

- One physical skill is one ledger record, even when it has many logical exposures.
- The primary navigation follows user decisions: Usage, Skills, Projects, and OpenTelemetry. Raw source files and configuration diagnostics remain available as secondary Files & diagnostics, not competing representations of skills.
- Policy is runtime-specific and explains whether it is explicit or derived.
- Non-auto skills show how to invoke them.
- One selected-agent skill-access view makes automatic, manual-only, model-only, disabled, undiscoverable, and review-needed policy directly filterable.
- Installed cache evidence never masquerades as active runtime exposure.
- Same-name definitions count as a conflict only when their active runtime exposure overlaps.
- Redundancy review separates byte-identical copies, same-name version drift, and heuristic purpose overlap instead of treating every name collision as the same problem.
- Skill and OTEL review signals rank evidence, limits, and a safe next action; high call volume and compactions are investigation prompts, not proven waste or causal attribution.
- Every actionable skill finding and OTEL review signal can be copied as an agent-ready brief. Skill follow-up rescans the same definition locations and reports detector-cleared, still detected, or unverified separately; OTEL improvements need a comparable fresh observation window.
- Every consolidation candidate exposes its confidence, evidence, affected runtimes, physical definitions, managed-cache boundary, and deterministic keep candidate.
- Cache-only duplication is counted separately and excluded from the default review queue so managed installation artifacts do not drown out owner-actionable findings.
- Duplicate savings mean local file bytes only. Context savings are not inferred, and absent activation telemetry never means unused.
- Project context distinguishes global, inherited, local, conditional, and installed-only evidence.
- Context-size estimates remain visibly approximate and never masquerade as live prompt measurements.
- Every source can be traced back to its logical path and, when linked, its physical path.
- Every usage value states its provenance.
- Local agent-log history, provider allowance, and OTEL activity are distinct ledgers; neither quotas nor overlapping telemetry are added to token history.
- Historical usage can be inspected by service, observed model or inferred model provider, time range, metric, and day/week/month scale. Model and provider mix comes from daily accounting. Project grouping and recent activity use separately labelled, verified session identities and may not reconcile to daily totals. Devin provider grouping remains in its independent local index.
- ccusage history is read directly and offline; CodeVetter is not a runtime dependency. Provider allowance has a manual check and an opt-in, throttled check on opening Usage. Devin's indexed daily history remains separate from ccusage accounting and must not appear as zero when unavailable.
- Codex full-reset credit expiry is shown only when the provider returns detail rows, and is labelled the latest reported expiry because the provider may cap those rows.
- OTEL sessions, tools, models, tokens, compactions, errors, and named skill injections remain distinct signals instead of being flattened into one activity score.
- OTEL is directly reachable and reports a disconnected local source as unavailable, never as zero activity.
- Overlapping operation durations are never added together as wall time.
- Local and read-only is the default boundary.
- Unknown or unsupported data remains visible as unavailable.
- Ignored agent settings and enabled MCP launchers that cannot resolve are surfaced once per root cause with file/line evidence and read-only remediation.

## Non-goals for v1

- Silently editing agent configuration; configuration health remains advisory and read-only.
- Capturing prompts, responses, tool arguments, or tool results.
- Acting as a TLS proxy or privileged network extension.
- Claiming exact bandwidth from logical request counters.
- Replacing the existing Codex OTEL stack.
- Treating skill injection as proof that a skill executed successfully or caused an outcome.
- Shipping, notarizing, or distributing before local behavior is proven.
- Reading document bodies during background discovery; previews are explicit, bounded user actions.
- Retaining or displaying config credentials, headers, environment values, MCP arguments, or unrelated configuration bodies; health checks inspect only bounded structural fields.
- Automatically deleting, merging, linking, or rewriting skills based on redundancy analysis.
