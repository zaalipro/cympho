defmodule CymphoWeb.WorkspaceController do
  use CymphoWeb, :controller

  alias Cympho.{Projects, Workspaces}

  action_fallback CymphoWeb.FallbackController

  # --- Project Workspaces ---

  def index(conn, %{"project_id" => project_id}) do
    with {:ok, project} <- Projects.get_company_project(company_id(conn), project_id) do
      workspaces = Workspaces.list_project_workspaces(project.id)
      json(conn, %{data: workspaces})
    end
  end

  def index(conn, _params) do
    workspaces = Workspaces.list_project_workspaces_for_company(company_id(conn))
    json(conn, %{data: workspaces})
  end

  def show(conn, %{"id" => id}) do
    case Workspaces.get_company_project_workspace(company_id(conn), id) do
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
    with {:ok, workspace_params} <- scoped_project_workspace_params(conn, workspace_params) do
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
  end

  def update(conn, %{"id" => id, "project_workspace" => workspace_params}) do
    case Workspaces.get_company_project_workspace(company_id(conn), id) do
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
    case Workspaces.get_company_project_workspace(company_id(conn), id) do
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

  def list_exec_workspaces(conn, %{"id" => pw_id} = params) do
    with {:ok, project_workspace} <-
           Workspaces.get_company_project_workspace(company_id(conn), pw_id) do
      opts = Keyword.take(params, [:status])
      workspaces = Workspaces.list_execution_workspaces(project_workspace.id, opts)
      json(conn, %{data: workspaces})
    end
  end

  def show_exec_workspace(conn, %{"id" => id}) do
    case Workspaces.get_company_execution_workspace(company_id(conn), id) do
      {:ok, workspace} ->
        json(conn, %{data: workspace})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def create_exec_workspace(conn, %{"id" => pw_id, "execution_workspace" => workspace_params}) do
    with {:ok, project_workspace} <-
           Workspaces.get_company_project_workspace(company_id(conn), pw_id) do
      params =
        workspace_params
        |> Map.put("company_id", project_workspace.company_id)
        |> Map.put("project_id", project_workspace.project_id)
        |> Map.put("project_workspace_id", project_workspace.id)

      case Workspaces.create_execution_workspace(params) do
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
  end

  def update_exec_workspace(conn, %{"id" => id, "execution_workspace" => workspace_params}) do
    case Workspaces.get_company_execution_workspace(company_id(conn), id) do
      {:ok, workspace} ->
        case Workspaces.update_execution_workspace(workspace, workspace_params) do
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

  def destroy_execution_workspace(conn, %{"id" => id}) do
    case Workspaces.get_company_execution_workspace(company_id(conn), id) do
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

  def detect_default_branch(conn, %{"id" => pw_id}) do
    with {:ok, project_workspace} <-
           Workspaces.get_company_project_workspace(company_id(conn), pw_id) do
      case Workspaces.detect_default_branch(project_workspace.id) do
        {:ok, result} ->
          json(conn, %{data: result})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> put_view(json: CymphoWeb.ErrorJSON)
          |> render(:"404")
      end
    end
  end

  def update_worktree_config(conn, %{
        "id" => pw_id,
        "config" => config
      }) do
    with {:ok, project_workspace} <-
           Workspaces.get_company_project_workspace(company_id(conn), pw_id) do
      case Workspaces.update_worktree_config(project_workspace.id, config) do
        {:ok, workspace} ->
          json(conn, %{data: workspace})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> put_view(json: CymphoWeb.ErrorJSON)
          |> render(:"404")
      end
    end
  end

  def seed_worktree(conn, %{
        "id" => ew_id,
        "seed_config" => seed_config
      }) do
    case Workspaces.get_company_execution_workspace(company_id(conn), ew_id) do
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
        "id" => ew_id,
        "secret_mappings" => secret_mappings
      }) do
    case Workspaces.get_company_execution_workspace(company_id(conn), ew_id) do
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

  def list_services(conn, %{"id" => ew_id}) do
    with {:ok, execution_workspace} <-
           Workspaces.get_company_execution_workspace(company_id(conn), ew_id) do
      services = Workspaces.list_runtime_services(execution_workspace.id)
      json(conn, %{data: services})
    end
  end

  def create_service(conn, %{"id" => ew_id, "runtime_service" => service_params}) do
    with {:ok, execution_workspace} <-
           Workspaces.get_company_execution_workspace(company_id(conn), ew_id) do
      params =
        service_params
        |> Map.put("company_id", execution_workspace.company_id)
        |> Map.put("project_id", execution_workspace.project_id)
        |> Map.put("project_workspace_id", execution_workspace.project_workspace_id)
        |> Map.put("execution_workspace_id", execution_workspace.id)

      case Workspaces.create_runtime_service(params) do
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
  end

  def show_runtime_service(conn, %{"id" => id}) do
    case Workspaces.get_company_runtime_service(company_id(conn), id) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      {:ok, service} ->
        json(conn, %{data: service})
    end
  end

  def start_service(conn, %{"id" => id}) do
    case Workspaces.get_company_runtime_service(company_id(conn), id) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      {:ok, service} ->
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
    case Workspaces.get_company_runtime_service(company_id(conn), id) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      {:ok, service} ->
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
    case Workspaces.get_company_runtime_service(company_id(conn), id) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      {:ok, service} ->
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

  def list_operations(conn, %{"id" => ew_id} = params) do
    with {:ok, execution_workspace} <-
           Workspaces.get_company_execution_workspace(company_id(conn), ew_id) do
      opts = Keyword.take(params, [:limit])
      operations = Workspaces.list_operations(execution_workspace.id, opts)
      json(conn, %{data: operations})
    end
  end

  # --- Leases ---

  def create_lease(conn, %{"lease" => lease_params}) do
    with {:ok, lease_params} <- scoped_lease_params(conn, lease_params) do
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
  end

  def revoke_lease(conn, %{"id" => id}) do
    case Workspaces.get_company_environment_lease(company_id(conn), id) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")

      {:ok, lease} ->
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

  defp company_id(conn), do: conn.assigns.current_company.id

  defp scoped_project_workspace_params(conn, params) do
    company_id = company_id(conn)

    case Map.get(params, "project_id") do
      project_id when is_binary(project_id) and project_id != "" ->
        case Projects.get_company_project(company_id, project_id) do
          {:ok, project} ->
            {:ok,
             params |> Map.put("company_id", company_id) |> Map.put("project_id", project.id)}

          {:error, _} ->
            {:error, :not_found}
        end

      _ ->
        {:ok, Map.put(params, "company_id", company_id)}
    end
  end

  defp scoped_lease_params(conn, params) do
    company_id = company_id(conn)

    with :ok <- validate_environment_ref(company_id, params["environment_id"]),
         :ok <- validate_execution_workspace_ref(company_id, params["execution_workspace_id"]) do
      {:ok, Map.put(params, "company_id", company_id)}
    end
  end

  defp validate_environment_ref(_company_id, nil), do: :ok
  defp validate_environment_ref(_company_id, ""), do: :ok

  defp validate_environment_ref(company_id, environment_id) do
    case Workspaces.get_company_environment(company_id, environment_id) do
      {:ok, _environment} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_execution_workspace_ref(_company_id, nil), do: :ok
  defp validate_execution_workspace_ref(_company_id, ""), do: :ok

  defp validate_execution_workspace_ref(company_id, execution_workspace_id) do
    case Workspaces.get_company_execution_workspace(company_id, execution_workspace_id) do
      {:ok, _execution_workspace} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
