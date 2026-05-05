defmodule CymphoWeb.IssueLabelJSON do
  alias Cympho.Labels.Label

  def index(%{labels: labels}), do: %{data: for(label <- labels, do: data(label))}

  defp data(%Label{} = label) do
    %{
      id: label.id,
      name: label.name,
      color: label.color
    }
  end
end
