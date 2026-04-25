defmodule CymphoWeb.WorkspaceController do
  use CymphoWeb, :controller

  alias Cympho.{Workspaces, Repo}

  action_fallback CymphoWeb.FallbackController

  # --- Project Workspaces ---

  def index(conn, %{"project_id" => project_id}) do
    workspaces = Workspaces.list_project_workspaces(project_id)
    json(conn, %{data: workspaces})
  end

  def index(conn, _params) do
    workspaces = Workspaces.list_project_workspaces_for_company(nil)
    json(conn, %{data: workspaces})
  end

  def show(conn, %{"id" => id}) do
    case Workspaces.get_project_workspace(id) do
      {:ok, workspace} ->
        json(conn, %{data: workspace})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def create(conn, %{"project_workspace" => workspace_params}) do
    case Workspaces.create_project_workspace(workspace_params) do
      {:ok, workspace} ->
        conn
        |> put_status(:created)
        |> json(%{data: workspace})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id, "project_workspace" => workspace_params}) do
    case Workspaces.get_project_workspace(id) do
      {:ok, workspace} ->
        case Workspaces.update_project_workspace(workspace, workspace_params) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def delete(conn, %{"id" => id}) do
    case Workspaces.get_project_workspace(id) do
      {:ok, workspace} ->
        case Workspaces.update_project_workspace(workspace, %{"visibility" => "archived"}) do
          {:ok, _} ->
            send_resp(conn, :no_content, "")

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  # --- Execution Workspaces ---

  def list_execution_workspaces(conn, %{"project_workspace_id" => pw_id} = params) do
    opts = Keyword.take(params, [:status])
    workspaces = Workspaces.list_execution_workspaces(pw_id, opts)
    json(conn, %{data: workspaces})
  end

  def show_execution_workspace(conn, %{"id" => id}) do
    case Workspaces.get_execution_workspace(id) do
      {:ok, workspace} ->
        json(conn, %{data: workspace})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def create_execution_workspace(conn, %{"execution_workspace" => workspace_params}) do
    case Workspaces.create_execution_workspace(workspace_params) do
      {:ok, workspace} ->
        conn
        |> put_status(:created)
        |> json(%{data: workspace})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def destroy_execution_workspace(conn, %{"id" => id}) do
    case Workspaces.get_execution_workspace(id) do
      {:ok, workspace} ->
        case Workspaces.destroy_execution_workspace(workspace) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  # --- Worktree Helpers ---

  def detect_default_branch(conn, %{"project_workspace_id" => pw_id}) do
    case Workspaces.detect_default_branch(pw_id) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def update_worktree_config(conn, %{
        "project_workspace_id" => pw_id,
        "config" => config
      }) do
    case Workspaces.update_worktree_config(pw_id, config) do
      {:ok, workspace} ->
        json(conn, %{data: workspace})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def seed_worktree(conn, %{
        "execution_workspace_id" => ew_id,
        "seed_config" => seed_config
      }) do
    case Workspaces.get_execution_workspace(ew_id) do
      {:ok, workspace} ->
        case Workspaces.seed_worktree(workspace, seed_config) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def inject_secrets(conn, %{
        "execution_workspace_id" => ew_id,
        "secret_mappings" => secret_mappings
      }) do
    case Workspaces.get_execution_workspace(ew_id) do
      {:ok, workspace} ->
        case Workspaces.inject_secrets(workspace, secret_mappings) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  # --- Runtime Services ---

  def list_runtime_services(conn, %{"execution_workspace_id" => ew_id}) do
    services = Workspaces.list_runtime_services(ew_id)
    json(conn, %{data: services})
  end

  def show_runtime_service(conn, %{"id" => id}) do
    case Repo.get(Cympho.Workspaces.RuntimeService, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      service ->
        json(conn, %{data: service})
    end
  end

  def create_runtime_service(conn, %{"runtime_service" => service_params}) do
    case Workspaces.create_runtime_service(service_params) do
      {:ok, service} ->
        conn
        |> put_status(:created)
        |> json(%{data: service})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def start_service(conn, %{"id" => id}) do
    case Repo.get(Cympho.Workspaces.RuntimeService, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      service ->
        case Workspaces.start_service(service) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end
    end
  end

  def stop_service(conn, %{"id" => id}) do
    case Repo.get(Cympho.Workspaces.RuntimeService, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      service ->
        case Workspaces.stop_service(service) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end
    end
  end

  def restart_service(conn, %{"id" => id}) do
    case Repo.get(Cympho.Workspaces.RuntimeService, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      service ->
        case Workspaces.restart_service(service) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end
    end
  end

  # --- Operations ---

  def list_operations(conn, %{"execution_workspace_id" => ew_id} = params) do
    opts = Keyword.take(params, [:limit])
    operations = Workspaces.list_operations(ew_id, opts)
    json(conn, %{data: operations})
  end

  # --- Leases ---

  def create_lease(conn, %{"lease" => lease_params}) do
    case Workspaces.create_lease(lease_params) do
      {:ok, lease} ->
        conn
        |> put_status(:created)
        |> json(%{data: lease})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def revoke_lease(conn, %{"id" => id}) do
    case Repo.get(Cympho.Workspaces.EnvironmentLease, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      lease ->
        case Workspaces.revoke_lease(lease) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end
    end
  end

  # --- Helpers ---

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
