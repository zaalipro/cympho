defmodule Cympho.Labels do
  @moduledoc "Labels context."
  alias Cympho.Repo
  alias Cympho.Labels.Label

  def list_labels, do: Repo.all(Label)

  def get_label!(id), do: Repo.get!(Label, id)

  def get_label(id) do
    case Repo.get(Label, id) do
      nil -> {:error, :not_found}
      label -> {:ok, label}
    end
  end

  def change_label(%Label{} = label, attrs \\ %{}) do
    Label.changeset(label, attrs)
  end

  def update_label(%Label{} = label, attrs) do
    label
    |> Label.changeset(attrs)
    |> Repo.update()
  end

  def create_label(attrs) do
    %Label{}
    |> Label.changeset(attrs)
    |> Repo.insert()
  end

  def delete_label(%Label{} = label) do
    Repo.delete(label)
  end
end
