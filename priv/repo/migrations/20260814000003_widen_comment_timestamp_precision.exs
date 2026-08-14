defmodule Cympho.Repo.Migrations.WidenCommentTimestampPrecision do
  @moduledoc """
  Comment timestamps were `timestamp(0)`, so every comment written inside one
  action batch shared the same second.

  `IssueDigest.last_action_receipt_audit/1` picks the newest meaningful agent
  comment and breaks ties by list position, and the comments association has no
  ordered preload — so with equal timestamps the answer depended on the order
  Postgres happened to return rows in. That decides a delivery gate: an agent
  that posts a note and then a `submit_review` receipt in the same batch could
  be rejected with "Latest handoff is missing receipt fields" because the audit
  looked at the earlier, non-receipt comment.

  Microsecond precision restores the ordering the code already assumes. It is
  widening only, so existing second-precision rows remain valid.
  """

  use Ecto.Migration

  def up do
    alter table(:comments) do
      modify :inserted_at, :utc_datetime_usec
      modify :updated_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:comments) do
      modify :inserted_at, :utc_datetime
      modify :updated_at, :utc_datetime
    end
  end
end
