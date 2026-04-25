defmodule CymphoWeb.SkillLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.Skills
  alias Cympho.Repo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Skills.get_skill(id) do
      {:ok, skill} ->
        skill = Repo.preload(skill, [:company, :project])

        {:ok,
         socket
         |> assign(:page_title, skill.name)
         |> assign(:skill, skill)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Skill not found")
         |> push_navigate(to: ~p"/skills")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, socket.assigns.skill.name)
  end

  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(:page_title, "Edit #{socket.assigns.skill.name}")
  end

  @impl true
  def handle_event("toggle_skill", _params, socket) do
    case Skills.toggle_skill(socket.assigns.skill) do
      {:ok, updated_skill} ->
        updated_skill = Repo.preload(updated_skill, [:company, :project])

        {:noreply,
         socket
         |> assign(:skill, updated_skill)
         |> put_flash(:info, "Skill #{if updated_skill.enabled, do: "enabled", else: "disabled"}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle skill")}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Skills.delete_skill(socket.assigns.skill) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Skill deleted successfully")
         |> push_navigate(to: ~p"/skills")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete skill")}
    end
  end
end
