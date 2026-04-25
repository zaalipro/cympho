defmodule Cympho.Comments.Parser do
  @mention_regex ~r/@([\w-]+)/
  @issue_ref_regex ~r/\b([A-Z]{2,10})-(\d+)\b/

  def extract_mentions(text) when is_binary(text) do
    Regex.scan(@mention_regex, text)
    |> Enum.map(fn [_, mention] -> mention end)
    |> Enum.uniq()
  end
  def extract_mentions(_), do: []

  def extract_issue_refs(text) when is_binary(text) do
    Regex.scan(@issue_ref_regex, text)
    |> Enum.map(fn [full, prefix, seq] ->
      %{ref: full, prefix: prefix, seq: String.to_integer(seq)}
    end)
    |> Enum.uniq_by(& &1.ref)
  end
  def extract_issue_refs(_), do: []

  def resolve_issue_refs(refs) when is_list(refs) do
    Enum.map(refs, fn %{prefix: prefix, seq: seq} = ref ->
      case find_issue_by_identifier(prefix, seq) do
        nil -> Map.put(ref, :resolved, false)
        issue -> Map.put(ref, :resolved, true) |> Map.put(:issue_id, issue.id)
      end
    end)
  end

  defp find_issue_by_identifier(prefix, seq) do
    alias Cympho.Repo
    alias Cympho.Issues.Issue
    import Ecto.Query

    identifier = "#{prefix}-#{seq}"
    Repo.one(from i in Issue, where: i.identifier == ^identifier, limit: 1)
  end
end
