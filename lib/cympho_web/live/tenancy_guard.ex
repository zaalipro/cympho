defmodule CymphoWeb.Live.TenancyGuard do
  @moduledoc """
  Helpers for LiveView mounts that load a record by ID and need to enforce
  tenancy.

  Use these instead of calling unscoped getters from a mount/3 — the unscoped
  variants leak records across companies.

  Two patterns are supported:

  1. The context exposes a scoped getter like `Projects.get_company_project/2`.
     Call it directly. The wrappers here are just for the cases where adding a
     scoped getter would be churn (e.g. tools/internal-only resources).

  2. The context only exposes an unscoped getter. Use `scoped_get/2` to wrap
     it: it calls the getter, checks `result.company_id` against the current
     company, and returns `{:error, :not_found}` on mismatch (we never confirm
     existence of records in another company).
  """

  @doc """
  Wraps a 1-arity getter. The getter must return `{:ok, struct}` /
  `{:error, :not_found}` and the returned struct must carry `:company_id`.

  Returns `{:error, :not_found}` if the current_company is nil — this should
  never happen in an authenticated session and we'd rather fail closed than
  silently return data.
  """
  def scoped_get(getter, current_company) when is_function(getter, 0) do
    case getter.() do
      {:ok, %{company_id: cid} = record} ->
        if match_company?(current_company, cid),
          do: {:ok, record},
          else: {:error, :not_found}

      {:ok, _record_without_company_id} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  defp match_company?(%{id: id}, cid) when is_binary(cid), do: id == cid
  defp match_company?(_, _), do: false
end
