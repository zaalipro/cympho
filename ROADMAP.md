# Roadmap

Cympho's direction is to become a calm, inspectable company operating system
for AI agents: simple for a nontechnical owner, deep enough for professional
operators, and safe to run autonomously. This is a direction document, not a
date or compatibility promise.

## Now: correctness and owner trust

- Bind issue checkout ownership to the actual run and make duplicate execution
  lose before provider spend.
- Route runtime usage through one persisted budget/incident enforcement path.
- Give owners one company-scoped queue for questions, reviews, approvals,
  failures, and spend/runtime decisions.
- Make Agent, Plan, and Ask task intent explicit in Simple and Advanced modes.
- Keep approval actions pinned to the revision the owner reviewed.

## Next: portable and observable operations

- Expand company import preview into selective merge/rename/skip workflows.
- Make onboarding resumable and add an improve-existing-company path.
- Harden dynamic viewport and safe-area behavior with repeatable Ego Lite
  evidence.
- Extend opt-in trace correlation while preserving the strict redaction
  contract.
- Prove one remote environment driver end to end before adding a provider
  matrix.

## Later: governed ecosystem and measurable improvement

- Add dynamic MCP/plugin tools with grants, approvals, revocation, rate limits,
  audits, and tenant isolation.
- Save deterministic evaluation suites and immutable runs with redacted
  provenance and owner feedback.
- Turn instruction improvements into reviewable, reversible proposals with
  post-change canaries.
- Grow reusable company/skill packages without synthetic ratings, downloads, or
  adoption claims.

The evidence-backed gap register, sequencing, and verification criteria are in
[`paperclip_gap.md`](paperclip_gap.md). Delivered behavior is reflected by
`mix cympho.compare`; open gaps remain visible instead of being hidden from the
report.
