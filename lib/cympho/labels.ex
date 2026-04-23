defmodule Cympho.Labels do
  @moduledoc """
  The Labels context for managing labels and their CRUD operations.
  """
  import Ecto.Query, warn: false

  alias Cympho.Repo
  alias Cympho.Labels.Label
  alias Cympho.Issues.Issue

  def list_labels(opts \\ []) do
    Label
    |> maybe_filter_by_project(opts)
    |> Repo.all()
  end

  defp maybe_filter_by_project(query, [project_id: project_id]) do
    where(query, project_id: ^project_id)
  end

  defp maybe_filter_by_project(query, _opts), do: query

  def get_label!(id), do: Repo.get!(Label, id)

  def get_label(id) do
    case Repo.get(Label, id) do
      nil -> {:error, :not_found}
      label -> {:ok, label}
    end
  end

  def create_label(attrs \\ %{}) do
    %Label{}
    |> Label.changeset(attrs)
    |> Repo.insert()
  end

  def update_label(%Label{} = label, attrs) do
    label
    |> Label.changeset(attrs)
    |> Repo.update()
  end

  def delete_label(%Label{} = label) do
    Repo.delete(label)
  end

  def change_label(%Label{} = label, attrs \\ %{}) do
    Label.changeset(label, attrs)
  end

  def list_labels_for_issue(%Issue{} = issue) do
    Repo.preload(issue, :labels).labels
  end

  def add_label_to_issue(%Issue{} = issue, %Label{} = label) do
    issue = Repo.preload(issue, :labels)
    labels = [label | issue.labels]
    issue |> Ecto.Changeset.change() |> Ecto.Changeset.put_assoc(:labels, labels) |> Repo.update()
  end

  def remove_label_from_issue(%Issue{} = issue, %Label{} = label) do
    issue = Repo.preload(issue, :labels)
    labels = Enum.reject(issue.labels, &(&1.id == label.id))
    issue |> Ecto.Changeset.change() |> Ecto.Changeset.put_assoc(:labels, labels) |> Repo.update()
  end

  def set_issue_labels(%Issue{} = issue, label_ids) when is_list(label_ids) do
    labels = Repo.all(from l in Label, where: l.id in ^label_ids)
    issue = Repo.preload(issue, :labels)
    issue |> Ecto.Changeset.change() |> Ecto.Changeset.put_assoc(:labels, labels) |> Repo.update()
  end
end
