defmodule Cympho.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  a sandboxed database connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Cympho.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Cympho.DataCase
      import Cympho.WaitHelpers
    end
  end

  setup tags do
    Cympho.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cympho.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Verifies that no residual unboxed fixtures remain in the database for the given company ID.
  """
  def verify_owned_fixture_cleanup!(repo, company_id) when is_binary(company_id) do
    import Ecto.Query

    check_fn = fn ->
      remaining_companies =
        repo.aggregate(from(c in Cympho.Companies.Company, where: c.id == ^company_id), :count)

      remaining_routines =
        repo.aggregate(
          from(r in Cympho.Routines.Routine, where: r.company_id == ^company_id),
          :count
        )

      remaining_issues =
        repo.aggregate(from(i in Cympho.Issues.Issue, where: i.company_id == ^company_id), :count)

      if remaining_companies > 0 or remaining_routines > 0 or remaining_issues > 0 do
        raise RuntimeError,
              "Owned fixture cleanup incomplete for #{company_id}: " <>
                "#{remaining_companies} companies, #{remaining_routines} routines, #{remaining_issues} issues remaining."
      else
        :ok
      end
    end

    Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, check_fn)
  end
end
