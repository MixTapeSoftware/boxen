# Formatter mode

Watch an existing PR and make the bot output on it easier to understand. Each pass does two things:

1. **PR note**: keep one formatter-owned top-level comment that states, in plain technical English, what the PR changes and where its open bot-raised issues stand. Revise it in place whenever its sources change.
2. **Clarifications**: where a bot comment or bot review finding is hard to follow, reply in its thread with a clearer restatement of the same issue.

Formatter never edits anyone else's comment, the PR title, or the PR description. It never edits code, commits, pushes, or resolves threads. Fixer owns fixes and thread resolution; reviewer owns findings; formatter owns only its note and its clarification replies.

## Fidelity is a hard requirement

Formatter restates; it never adds. Every claim in a formatter comment must trace to a source comment, and the restatement must keep the source's meaning, scope, certainty, and severity.

- No new facts, findings, causes, fixes, scores, or opinions, even ones that are correct and verifiable from the code. Formatter may read code only to place an anchor or check that a diagram names the right components, never to extend what the source said.
- Keep hedges as hedges ("may", "if X then") and keep claims as claims. Don't upgrade or downgrade severity, and don't merge two sources' claims into one stronger claim.
- Keep every concrete detail the source gives: file paths, line numbers, identifiers, error text, values, scores, and suggested fixes.
- When the source is ambiguous, keep the ambiguity and say plainly that the source does not specify; never resolve it by guessing.
- When a fact matters but no source states it, leave it out.

If a restatement cannot be clearer without changing meaning, don't post it.

## Run formatting in a separate agent

Rewriting for clarity is a different kind of work from reasoning about code, and doing both in one context degrades both. **Always do the formatting in a dedicated sub-agent**, never inline in a fixer or reviewer session, and never in the formatter coordinator's own context:

- The **coordinator** (this loop) polls the PR, collects source comments, tracks state, and posts or edits formatter comments.
- Each pass, the coordinator starts a fresh **formatting sub-agent** and gives it only the source comment bodies (with author, link, and anchor), the current PR note if one exists, and this file. The sub-agent returns the revised note (or "unchanged") and a list of clarifications, each with the source comment it restates or "skip".
- The sub-agent also returns a **claim map** for each output: each sentence, list item, and diagram node or edge, paired with the source sentence it restates. The coordinator rejects any output with an unmapped claim, a dropped source detail, or a changed hedge, and posts nothing for it that pass.

When the harness cannot start sub-agents, report that as a blocker and stop rather than formatting inline.

## Sources

Only bot-authored content is formatted. Classify authors with the fixer's rules in `SKILL.md`: GitHub `Bot` accounts, `[bot]` logins, known review/CI bots, and comments from the user's account that carry the fixer or reviewer footer. Formatter's own comments are never sources. Human comments are never sources and formatter never posts in a human thread; a bot thread that gains a human reply is a human thread from then on.

Sources include bot PR summary comments, bot review summaries, inline bot review findings, top-level bot comments, and fixer replies. The PR description is a source for the note's "what changes" section only, and only as written.

## PR note

The note is a single top-level PR comment from the user's account, created on the first pass and edited in place on later passes (`PATCH repos/{owner}/{repo}/issues/comments/<id>`), never re-posted. Find it by the marker below; if several exist, edit the newest and leave the rest alone.

Write it in plain technical English: short declarative sentences, concrete names, no marketing tone, no filler. Structure:

- **What this PR changes**: from the PR description and bot summaries.
- **Open issues**: one entry per unresolved bot finding, with its file and line, its source score when the source gave one, and a link to the source thread.
- **Addressed**: findings fixer reports as fixed or declined, with the commit or reason the source states.

Revise the note whenever a source changes: a new head commit, a new or edited bot summary, a new finding, or a thread resolved. When nothing changed, don't edit it. End the note with:

```html
<!-- botfight:formatter note sources=<sha256> -->
```

where `sources` is the lowercase hex SHA-256 of the sorted source comment IDs and their `updated_at` values, joined by newlines. A matching digest means the note is current.

## Clarifications

Post a clarification only where it usefully improves on the source: a finding buried in a long summary, a wall of text, an issue whose control flow or data flow is hard to follow from prose, or several findings that describe one problem. Skip comments that are already clear, short status replies, and zero-findings summaries.

A clarification is a reply in the source's review thread, or, for a top-level source, a top-level comment that links and quotes the first line of the source. Lead with a one-sentence statement of the issue, then the trigger, the impact, and the suggested fix, each as the source gave them.

Use a visualization only where it conveys the core issue better than prose, and draw only what the source describes:

- **Mermaid** (` ```mermaid `, which GitHub renders) for sequences, state transitions, and data flow across components, such as a race between two requests or a missing auth check on one path.
- **ASCII** in a plain code block for small structures: a before/after table, a timeline, a call stack, or a memory or buffer layout.

Each clarification ends with this marker, which ties it to the exact source revision:

```html
<!-- botfight:formatter source=<comment-node-id> rev=<sha256 of source body> -->
```

Post at most one clarification per source revision. When a source is edited, post a new clarification only if the change affects the restatement, and link the earlier one.

## Loop

Use the shared invocation rules, timing defaults, and deadline handling in `SKILL.md`: `/botfight formatter [<PR-number-or-URL>] [<interval> <duration>]`, continued as `formatter <PR-URL> until <ISO-8601 deadline> every <interval>`.

1. **Check the deadline first**, including on continuations. Resolve the supplied PR, or the current branch's PR, and pin it for the loop. If no PR exists, report that and stop; never create one.
2. **Fetch state**: PR status, head SHA, description, top-level comments, reviews, and review threads (paginate). Closed or merged means exit.
3. **Collect sources** and compare against carried state and existing formatter markers. If the note digest matches and every source revision already has a clarification or a recorded skip, wait.
4. **Format in a sub-agent** as described above, and check its claim maps.
5. **Publish**: edit or create the note, then post clarifications. Before posting, re-fetch each source thread; skip any that resolved or gained a human reply since step 2.
6. **Keep watching until the deadline**, cancellation, or PR close/merge, using a recurring wakeup capped at time remaining. Carry the PR URL, deadline, interval, posting login, note comment ID and digest, and the source revisions already clarified or skipped.

## Coordination with fixer and reviewer

Formatter comments carry the formatter footer from `SKILL.md`, so fixer and reviewer treat them as bot comments, but they are restatements, not findings: fixer does not score, reply to, or count them as new bot comments, and reviewer does not treat them as existing findings to deduplicate against. A formatter reply does not stop fixer from resolving a bot thread.

## Exit report

Report why the loop ended, iterations run, the note's link and last revision, clarifications posted (with links and the source each restates), outputs rejected by the claim-map check, and any blocker.
