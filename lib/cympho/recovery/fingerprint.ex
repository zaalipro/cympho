defmodule Cympho.Recovery.Fingerprint do
  @moduledoc "Canonical, redacted fingerprints for stranded work sources."

  @version 1

  @spec for_run(map(), map()) :: {String.t(), map()}
  def for_run(run, issue) do
    error_family = error_family(Map.get(run, :error_reason) || Map.get(run, "error_reason"))

    snapshot = %{
      "version" => @version,
      "source_type" => "heartbeat_run",
      "company_id" =>
        id(Map.get(run, :company_id) || Map.get(run, "company_id") || Map.get(issue, :company_id)),
      "run_id" => id(Map.get(run, :id) || Map.get(run, "id")),
      "issue_id" =>
        id(Map.get(run, :issue_id) || Map.get(run, "issue_id") || Map.get(issue, :id)),
      "agent_id" => id(Map.get(run, :agent_id) || Map.get(run, "agent_id")),
      "run_status" => value(Map.get(run, :status) || Map.get(run, "status")),
      "issue_status" => value(Map.get(issue, :status) || Map.get(issue, "status")),
      "issue_lock_version" => Map.get(issue, :lock_version) || Map.get(issue, "lock_version"),
      "lock_version" => Map.get(issue, :lock_version) || Map.get(issue, "lock_version"),
      "checkout_run_id" =>
        id(Map.get(issue, :checkout_run_id) || Map.get(issue, "checkout_run_id")),
      "error_family" => error_family
    }

    hash(snapshot)
  end

  @spec for_issue_checkout(map()) :: {String.t(), map()}
  def for_issue_checkout(issue) do
    snapshot = %{
      "version" => @version,
      "source_type" => "issue_checkout",
      "issue_id" => id(Map.get(issue, :id) || Map.get(issue, "id")),
      "company_id" => id(Map.get(issue, :company_id) || Map.get(issue, "company_id")),
      "assignee_id" => id(Map.get(issue, :assignee_id) || Map.get(issue, "assignee_id")),
      "issue_status" => value(Map.get(issue, :status) || Map.get(issue, "status")),
      "checkout_run_id" =>
        id(Map.get(issue, :checkout_run_id) || Map.get(issue, "checkout_run_id")),
      "checked_out_at" =>
        truncate_datetime(Map.get(issue, :checked_out_at) || Map.get(issue, "checked_out_at")),
      "lock_version" => Map.get(issue, :lock_version) || Map.get(issue, "lock_version")
    }

    hash(snapshot)
  end

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

  defp truncate_datetime(nil), do: nil

  defp truncate_datetime(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp truncate_datetime(value), do: value

  defp error_family(nil), do: nil

  defp error_family(reason) do
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
