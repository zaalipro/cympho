defmodule CymphoWeb.LabelJSON do
  alias Cympho.Labels.Label

  def label_data(%Label{} = label) do
    %{
      id: label.id,
      name: label.name,
      color: label.color,
      project_id: label.project_id,
      inserted_at: label.inserted_at,
      updated_at: label.updated_at
    }
  end
end
