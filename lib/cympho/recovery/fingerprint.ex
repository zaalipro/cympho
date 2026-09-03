defmodule Cympho.Recovery.Fingerprint do
  @moduledoc "Canonical, redacted fingerprints for stranded work sources."

  @version 1

  @spec for_run(map(), map()) :: {String.t(), map()}
  def for_run(run, issue) do
    error_family = do_error_family(field(run, :error_reason))

    snapshot = %{
      "version" => @version,
      "source_type" => "heartbeat_run",
      "company_id" => id(field(run, :company_id) || field(issue, :company_id)),
      "run_id" => id(field(run, :id)),
      "issue_id" => id(field(run, :issue_id) || field(issue, :id)),
      "agent_id" => id(field(run, :agent_id)),
      "run_status" => value(field(run, :status)),
      "issue_status" => value(field(issue, :status)),
      "issue_lock_version" => field(issue, :lock_version),
      "lock_version" => field(issue, :lock_version),
      "checkout_run_id" => id(field(issue, :checkout_run_id)),
      "error_family" => error_family
    }

    hash(snapshot)
  end

  @spec for_issue_checkout(map()) :: {String.t(), map()}
  def for_issue_checkout(issue) do
    snapshot = %{
      "version" => @version,
      "source_type" => "issue_checkout",
      "issue_id" => id(field(issue, :id)),
      "company_id" => id(field(issue, :company_id)),
      "assignee_id" => id(field(issue, :assignee_id)),
      "issue_status" => value(field(issue, :status)),
      "checkout_run_id" => id(field(issue, :checkout_run_id)),
      "lock_version" => field(issue, :lock_version)
    }

    hash(snapshot)
  end

  @doc "Returns the bounded, redacted error family used in run fingerprints."
  @spec error_family(term()) :: String.t() | nil
  def error_family(reason), do: do_error_family(reason)

  defp hash(snapshot) do
    canonical = snapshot |> sort_maps() |> Jason.encode!()
    {:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower), snapshot}
  end

  defp sort_maps(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), sort_maps(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort_maps(value) when is_list(value), do: Enum.map(value, &sort_maps/1)
  defp sort_maps(value), do: value

  defp id(nil), do: nil
  defp id(%{id: id}), do: id(id)
  defp id(value) when is_binary(value), do: value
  defp id(value), do: to_string(value)

  defp value(value) when is_atom(value), do: Atom.to_string(value)
  defp value(value), do: value

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_, _), do: nil

  defp do_error_family(nil), do: nil

  defp do_error_family(reason) do
    text = reason |> inspect(limit: 20) |> String.downcase()

    cond do
      String.contains?(text, ["timeout", "timed out"]) -> "timeout"
      String.contains?(text, ["auth", "credential", "token", "secret"]) -> "authentication"
      String.contains?(text, ["rate", "429", "thrott"]) -> "rate_limited"
      String.contains?(text, ["network", "connect", "econn"]) -> "network"
      String.contains?(text, ["cancel"]) -> "cancelled"
      true -> "unknown"
    end
  end
end
