## Summary
- Adds contract nudge actions to Operations and issue detail.
- Keeps repair instructions tied to the issue digest contract.

## Issue
- CYM-42: Add contract nudges
- Branch: `CYM-42/add-contract-nudges`

## Task List
- [x] Add backend nudge planning for prompt contracts
- [x] Add Operations button for contract gaps
- [x] Add issue detail button beside missing fields

## Validation
- [x] mix test test/cympho/review_nudges_test.exs
- [x] mix test test/cympho_web/live/operations_live_test.exs

## Risk and Rollback
- Risk: contract nudges could duplicate review nudges.
- Rollback: remove contract blocker keys and UI buttons.

## Reviewer Notes
- Check that queued nudges appear in the agent inbox.
