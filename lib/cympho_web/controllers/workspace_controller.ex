defmodule CymphoWeb.WorkspaceController do
  use CymphoWeb, :controller

  alias Cympho.{Issues, Projects, Workspaces}

  alias Cympho.Workspaces.{
    EnvironmentLease,
    ExecutionWorkspace,
    ProjectWorkspace,
    RuntimeService,
    WorkspaceOperation
  }

  @execution_workspace_writable_fields ~w(
    mode
    strategy_type
    name
    cwd
    repo_url
    base_ref
    branch_name
    provider_type
    metadata
  )
  @execution_workspace_create_relation_fields ~w(
    source_issue_id
    derived_from_execution_workspace_id
  )
  @lease_writable_fields ~w(
    lease_policy
    environment_id
    issue_id
    expires_at
    metadata
  )

  action_fallback CymphoWeb.FallbackController

  # --- Project Workspaces ---

  def index(conn, %{"project_id" => project_id}) do
    with {:ok, project} <- Projects.get_company_project(company_id(conn), project_id) do
      workspaces = Workspaces.list_project_workspaces(project.id)
      json(conn, %{data: encode_records(workspaces)})
    end
  end

  def index(conn, _params) do
    workspaces = Workspaces.list_project_workspaces_for_company(company_id(conn))
    json(conn, %{data: encode_records(workspaces)})
  end

  def show(conn, %{"id" => id}) do
    case Workspaces.get_company_project_workspace(company_id(conn), id) do
      {:ok, workspace} ->
        json(conn, %{data: encode_records(workspace)})

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
          |> json(%{data: encode_records(workspace)})

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
            json(conn, %{data: encode_records(updated)})

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
      opts = if status = params["status"], do: [status: status], else: []
      workspaces = Workspaces.list_execution_workspaces(project_workspace.id, opts)
      json(conn, %{data: encode_records(workspaces)})
    end
  end

  def show_exec_workspace(conn, %{"id" => id}) do
    case Workspaces.get_company_execution_workspace(company_id(conn), id) do
      {:ok, workspace} ->
        json(conn, %{data: encode_records(workspace)})

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
        |> Map.take(
          @execution_workspace_writable_fields ++ @execution_workspace_create_relation_fields
        )
        |> Map.put("company_id", project_workspace.company_id)
        |> Map.put("project_id", project_workspace.project_id)
        |> Map.put("project_workspace_id", project_workspace.id)
        |> Map.put("status", "open")
        |> Map.put("opened_at", DateTime.utc_now() |> DateTime.truncate(:second))

      case Workspaces.create_execution_workspace(params) do
        {:ok, workspace} ->
          conn
          |> put_status(:created)
          |> json(%{data: encode_records(workspace)})

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
        case Workspaces.update_execution_workspace(
               workspace,
               Map.take(workspace_params, @execution_workspace_writable_fields)
             ) do
          {:ok, updated} ->
            json(conn, %{data: encode_records(updated)})

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
            json(conn, %{data: encode_records(updated)})

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

  def destroy_exec_workspace(conn, params), do: destroy_execution_workspace(conn, params)

  # --- Worktree Helpers ---

  def detect_default_branch(conn, %{"id" => pw_id}) do
    with {:ok, project_workspace} <-
           Workspaces.get_company_project_workspace(company_id(conn), pw_id) do
      case Workspaces.detect_default_branch(project_workspace.id) do
        {:ok, %{project_workspace: workspace} = result} ->
          json(conn, %{data: %{result | project_workspace: encode_records(workspace)}})

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
          json(conn, %{data: encode_records(workspace)})

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
            json(conn, %{data: encode_records(updated)})

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
            json(conn, %{data: encode_records(updated)})

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
      json(conn, %{data: encode_records(services)})
    end
  end

  def create_service(conn, %{"id" => ew_id, "runtime_service" => service_params}) do
    with {:ok, execution_workspace} <-
           Workspaces.get_company_execution_workspace(company_id(conn), ew_id) do
      case Workspaces.create_runtime_service(execution_workspace, service_params) do
        {:ok, service} ->
          conn
          |> put_status(:created)
          |> json(%{data: encode_records(service)})

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
        json(conn, %{data: encode_records(service)})
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
            json(conn, %{data: encode_records(updated)})

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
            json(conn, %{data: encode_records(updated)})

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
            json(conn, %{data: encode_records(updated)})

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
      opts =
        if limit = params["limit"] do
          case Integer.parse(to_string(limit)) do
            {int, _} -> [limit: int]
            :error -> []
          end
        else
          []
        end

      operations = Workspaces.list_operations(execution_workspace.id, opts)
      json(conn, %{data: encode_records(operations)})
    end
  end

  # --- Leases ---

  def create_lease(conn, %{"id" => execution_workspace_id, "lease" => lease_params}) do
    with {:ok, execution_workspace} <-
           Workspaces.get_company_execution_workspace(company_id(conn), execution_workspace_id),
         {:ok, lease_params} <-
           scoped_lease_params(conn, execution_workspace, lease_params) do
      case Workspaces.create_lease(lease_params) do
        {:ok, lease} ->
          conn
          |> put_status(:created)
          |> json(%{data: encode_records(lease)})

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
            json(conn, %{data: encode_records(updated)})

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

  defp scoped_lease_params(conn, execution_workspace, params) do
    company_id = company_id(conn)

    with :ok <- validate_environment_ref(company_id, params["environment_id"]),
         :ok <- validate_issue_ref(company_id, params["issue_id"]) do
      {:ok,
       params
       |> Map.take(@lease_writable_fields)
       |> Map.put("company_id", company_id)
       |> Map.put("execution_workspace_id", execution_workspace.id)
       |> Map.put("status", "active")}
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

  defp validate_issue_ref(_company_id, nil), do: :ok
  defp validate_issue_ref(_company_id, ""), do: :ok

  defp validate_issue_ref(company_id, issue_id) do
    case Issues.get_company_issue(company_id, issue_id) do
      {:ok, _issue} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp encode_records(records) when is_list(records), do: Enum.map(records, &encode_records/1)

  defp encode_records(%ProjectWorkspace{} = workspace) do
    Map.take(workspace, [
      :id,
      :company_id,
      :project_id,
      :name,
      :cwd,
      :repo_ref,
      :default_ref,
      :is_primary,
      :source_type,
      :visibility,
      :remote_provider,
      :inserted_at,
      :updated_at
    ])
  end

  defp encode_records(%ExecutionWorkspace{} = workspace) do
    Map.take(workspace, [
      :id,
      :company_id,
      :project_id,
      :project_workspace_id,
      :source_issue_id,
      :derived_from_execution_workspace_id,
      :mode,
      :strategy_type,
      :name,
      :status,
      :cwd,
      :base_ref,
      :branch_name,
      :provider_type,
      :last_used_at,
      :opened_at,
      :closed_at,
      :cleanup_eligible_at,
      :cleanup_reason,
      :inserted_at,
      :updated_at
    ])
  end

  defp encode_records(%RuntimeService{} = service) do
    Map.take(service, [
      :id,
      :company_id,
      :project_id,
      :project_workspace_id,
      :issue_id,
      :execution_workspace_id,
      :scope_type,
      :scope_id,
      :service_name,
      :reuse_key,
      :status,
      :lifecycle,
      :cwd,
      :port,
      :preview_ref,
      :provider,
      :owner_agent_id,
      :started_by_run_id,
      :last_used_at,
      :started_at,
      :stopped_at,
      :health_status,
      :inserted_at,
      :updated_at
    ])
  end

  defp encode_records(%WorkspaceOperation{} = operation) do
    Map.take(operation, [
      :id,
      :company_id,
      :execution_workspace_id,
      :phase,
      :cwd,
      :status,
      :exit_code,
      :log_store,
      :log_bytes,
      :log_sha256,
      :log_compressed,
      :started_at,
      :finished_at,
      :inserted_at,
      :updated_at
    ])
  end

  defp encode_records(%EnvironmentLease{} = lease) do
    Map.take(lease, [
      :id,
      :company_id,
      :environment_id,
      :execution_workspace_id,
      :issue_id,
      :status,
      :lease_policy,
      :provider,
      :acquired_at,
      :last_used_at,
      :expires_at,
      :released_at,
      :failure_reason,
      :cleanup_status,
      :inserted_at,
      :updated_at
    ])
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
