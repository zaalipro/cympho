defmodule CymphoWeb.LaunchItemJSON do
  alias Cympho.LaunchItems.LaunchItem

  def index(%{launch_items: launch_items}) do
    %{data: Enum.map(launch_items, &data/1)}
  end

  def show(%{launch_item: %LaunchItem{} = launch_item}) do
    %{data: data(launch_item)}
  end

  defp data(%LaunchItem{} = launch_item) do
    %{
      id: launch_item.id,
      title: launch_item.title,
      owner_user_id: launch_item.owner_user_id,
      owner: owner_data(launch_item.owner_user),
      status: launch_item.status,
      is_blocked: launch_item.is_blocked,
      inserted_at: launch_item.inserted_at,
      updated_at: launch_item.updated_at
    }
  end

  defp owner_data(%{id: id, name: name, email: email}) do
    %{id: id, name: name, email: email}
  end

  defp owner_data(_owner), do: nil
end
