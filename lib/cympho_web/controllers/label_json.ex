defmodule CymphoWeb.LabelJSON do
  alias Cympho.Labels.Label
  def index(%{labels: labels}), do: %{data: for(label <- labels, do: data(label))}
  def show(%{label: label}), do: %{data: data(label)}
  defp data(%Label{} = label) do
    %{id: label.id, name: label.name, color: label.color, description: label.description,
      inserted_at: label.inserted_at, updated_at: label.updated_at}
  end
end
