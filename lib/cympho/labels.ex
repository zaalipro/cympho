defmodule Cympho.Labels do
  @moduledoc "Labels context."
  alias Cympho.Repo
  alias Cympho.Labels.Label

  def list_labels, do: Repo.all(Label)

  def get_label!(id), do: Repo.get!(Label, id)

  def create_label(attrs) do
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
    issue_with_labels = Repo.preload(issue, :labels)

    case Enum.any?(issue_with_labels.labels, &(&1.id == label.id)) do
      true -> {:ok, issue_with_labels}
      false ->
        updated_labels = [label | issue_with_labels.labels]

        issue_with_labels
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_assoc(:labels, updated_labels)
        |> optimistic_lock(:lock_version)
        |> Repo.update()
    end
  end

  def remove_label_from_issue(%Issue{} = issue, %Label{} = label) do
    issue_with_labels = Repo.preload(issue, :labels)
    labels = Enum.reject(issue_with_labels.labels, &(&1.id == label.id))

    issue_with_labels
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:labels, labels)
    |> optimistic_lock(:lock_version)
    |> Repo.update()
  end

  def set_issue_labels(%Issue{} = issue, label_ids) when is_list(label_ids) do
    labels = Repo.all(from l in Label, where: l.id in ^label_ids)
    issue_with_labels = Repo.preload(issue, :labels)

    issue_with_labels
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:labels, labels)
    |> optimistic_lock(:lock_version)
    |> Repo.update()
  end
end
