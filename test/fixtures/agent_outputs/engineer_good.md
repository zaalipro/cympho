[delivery] What happened: implemented issue detail contract nudges and linked the Operations action. Files changed: lib/cympho/review_nudges.ex, lib/cympho_web/live/operations_live/index.ex, tests. Verification: ran focused Operations and Issue LiveView tests. Risks: existing review nudge dedupe must keep contract and review nudges distinct. Current state: ready for CTO review. Next decision: CTO reviews behavior and PR evidence.

```cympho-actions
{
  "actions": [
    {
      "type": "comment",
      "body": "[delivery] What happened: implemented issue detail contract nudges and linked the Operations action. Files changed: lib/cympho/review_nudges.ex, lib/cympho_web/live/operations_live/index.ex, tests. Verification: ran focused Operations and Issue LiveView tests. Risks: existing review nudge dedupe must keep contract and review nudges distinct. Current state: ready for CTO review. Next decision: CTO reviews behavior and PR evidence."
    },
    {
      "type": "submit_review",
      "role": "cto",
      "notes": "Focused tests passed."
    }
  ]
}
```
