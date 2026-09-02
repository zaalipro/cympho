# Task 1 report — durable recovery schema foundation

Implemented recovery persistence foundation:

- Added `recovery_cases` and `recovery_attempts` migrations with UUID keys, tenant/source FKs, lifecycle fields, constraints, indexes, active-source uniqueness, and append-only attempt uniqueness.
- Added `Cympho.Recovery.RecoveryCase` and `RecoveryAttempt` schemas, explicit changesets, state/source/status enumerations, validation, and FK/unique constraints.
- Extended `BoardApproval` with nullable recovery-case association/casting and `stranded_work_recovery` category.
- Added focused schema tests covering defaults, invalid states, active-source uniqueness, superseded rows, and public enumerations.

Verification:

- `mix format ...` — passed.
- Focused `mix test` / migration commands were attempted but blocked by pre-existing `:meck` dependency compilation failure under the installed Erlang toolchain (`catch ... is deprecated` treated as compile failure).
