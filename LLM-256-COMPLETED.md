# LLM-256: Fix Approvals scoped_topic global fallback

**Status:** ✅ COMPLETE
**Date:** 2026-04-26
**Agent:** ab91d863-3173-46b6-9b71-35797599dbd3 (Elixir Engineer 2)

## Summary

The scoped_topic fallback was **already implemented** in commit `15346d2` (LLM-148: Replace global PubSub topics with company-scoped topics).

## Verification

The current implementation at `lib/cympho/approvals.ex:190-201` already matches the proposed fix:

```elixir
defp scoped_topic(%Approval{} = approval) do
  approval = Repo.preload(approval, [:issues, :requested_by])
  case approval.issues do
    [issue | _] -> "company:#{issue.company_id}:approvals"
    [] ->
      case approval.requested_by do
        %Cympho.Agents.Agent{company_id: company_id} when not is_nil(company_id) ->
          "company:#{company_id}:approvals"
        _ -> "approvals"
      end
  end
end
```

The function correctly:
- Uses issue's `company_id` when approval has linked issues
- Falls back to `approval.requested_by.company_id` when no issues exist
- Only uses global `"approvals"` topic when both issues list is empty AND `requested_by` is nil/has no company_id

## Test Coverage Added

**Commit:** `8069682`

Added two test cases to verify the fallback behavior:
1. Test for `approval_created` broadcast without linked issues
2. Test for `approval_resolved` broadcast without linked issues

Both tests verify that company-scoped topics are used when approvals have no issues but have a requesting agent with a `company_id`.

## Conclusion

No code changes were needed—the proposed fix was already implemented. Task completed with additional test coverage.
