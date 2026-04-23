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

  def delete_label(%Label{} = label), do: Repo.delete(label)
end
