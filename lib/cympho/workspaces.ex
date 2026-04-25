defmodule Cympho.Workspaces do
  @moduledoc """
  The Workspaces context manages project workspaces, execution workspaces,
  runtime services, operations, and environment leases.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo

  alias Cympho.Workspaces.ProjectWorkspace
  alias Cympho.Workspaces.ExecutionWorkspace
  alias Cympho.Workspaces.RuntimeService
  alias Cympho.Workspaces.WorkspaceOperation
  alias Cympho.Workspaces.EnvironmentLease

  # --- Project Workspaces ---

  def list_project_workspaces(project_id) do
    from(pw in ProjectWorkspace, where: pw.project_id == ^project_id)
    |> Repo.all()
  end

  def list_project_workspaces_for_company(company_id) do
    from(pw in ProjectWorkspace, where: pw.company_id == ^company_id)
    |> Repo.all()
  end

  def get_project_workspace!(id), do: Repo.get!(ProjectWorkspace, id)

  def get_project_workspace(id) do
    case Repo.get(ProjectWorkspace, id) do
      nil -> {:error, :not_found}
      pw -> {:ok, pw}
    end
  end

  def create_project_workspace(attrs \\ %{}) do
    %ProjectWorkspace{}
    |> ProjectWorkspace.changeset(attrs)
    |> Repo.insert()
  end

  def update_project_workspace(%ProjectWorkspace{} = pw, attrs) do
    pw
    |> ProjectWorkspace.changeset(attrs)
    |> Repo.update()
  end

  # --- Execution Workspaces ---

  def list_execution_workspaces(project_workspace_id, opts \\ []) do
    query =
      from(ew in ExecutionWorkspace,
        where: ew.project_workspace_id == ^project_workspace_id
      )

    query = maybe_filter_by_status(query, Keyword.get(opts, :status))
    Repo.all(query)
  end

  defp maybe_filter_by_status(query, nil), do: query
  defp maybe_filter_by_status(query, status), do: where(query, status: ^status)

  def get_execution_workspace!(id), do: Repo.get!(ExecutionWorkspace, id)

  def get_execution_workspace(id) do
    case Repo.get(ExecutionWorkspace, id) do
      nil -> {:error, :not_found}
      ew -> {:ok, ew}
    end
  end

  def get_execution_workspace_for_issue(issue_id) do
    case Repo.get_by(ExecutionWorkspace, source_issue_id: issue_id) do
      nil -> {:error, :not_found}
      ew -> {:ok, ew}
    end
  end

  def create_execution_workspace(attrs \\ %{}) do
    %ExecutionWorkspace{}
    |> ExecutionWorkspace.changeset(attrs)
    |> Repo.insert()
  end

  def update_execution_workspace(%ExecutionWorkspace{} = ew, attrs) do
    ew
    |> ExecutionWorkspace.changeset(attrs)
    |> Repo.update()
  end

  def destroy_execution_workspace(%ExecutionWorkspace{} = ew) do
    update_execution_workspace(ew, %{status: "closed", closed_at: DateTime.utc_now()})
  end

  # --- Worktree Helpers ---

  def detect_default_branch(project_workspace_id) do
    case get_project_workspace(project_workspace_id) do
      {:ok, pw} ->
        default_ref = pw.default_ref || pw.repo_ref || "main"
        {:ok, %{default_branch: default_ref, project_workspace: pw}}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def update_worktree_config(project_workspace_id, config) do
    case get_project_workspace(project_workspace_id) do
      {:ok, pw} ->
        metadata = Map.merge(pw.metadata || %{}, %{"worktree_config" => config})
        update_project_workspace(pw, %{metadata: metadata})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Seed & Secrets ---

  def seed_worktree(%ExecutionWorkspace{} = ew, seed_config) do
    metadata = Map.merge(ew.metadata || %{}, %{"seed_config" => seed_config})
    update_execution_workspace(ew, %{metadata: metadata})
  end

  def inject_secrets(%ExecutionWorkspace{} = ew, secret_mappings) do
    metadata = Map.merge(ew.metadata || %{}, %{"secret_mappings" => secret_mappings})
    update_execution_workspace(ew, %{metadata: metadata})
  end

  # --- Runtime Services ---

  def list_runtime_services(execution_workspace_id) do
    from(rs in RuntimeService,
      where: rs.execution_workspace_id == ^execution_workspace_id
    )
    |> Repo.all()
  end

  def get_runtime_service!(id), do: Repo.get!(RuntimeService, id)

  def create_runtime_service(attrs \\ %{}) do
    %RuntimeService{}
    |> RuntimeService.changeset(attrs)
    |> Repo.insert()
  end

  def start_service(%RuntimeService{} = svc) do
    svc
    |> RuntimeService.changeset(%{
      status: "running",
      started_at: DateTime.utc_now(),
      stopped_at: nil
    })
    |> Repo.update()
  end

  def stop_service(%RuntimeService{} = svc) do
    svc
    |> RuntimeService.changeset(%{status: "stopped", stopped_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def restart_service(%RuntimeService{} = svc) do
    svc
    |> RuntimeService.changeset(%{
      status: "running",
      started_at: DateTime.utc_now(),
      stopped_at: nil
    })
    |> Repo.update()
  end

  # --- Operations ---

  def list_operations(execution_workspace_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(op in WorkspaceOperation,
      where: op.execution_workspace_id == ^execution_workspace_id,
      order_by: [desc: op.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  # --- Leases ---

  def create_lease(attrs \\ %{}) do
    %EnvironmentLease{}
    |> EnvironmentLease.changeset(attrs)
    |> Repo.insert()
  end

  def revoke_lease(%EnvironmentLease{} = lease) do
    lease
    |> EnvironmentLease.revoke_changeset()
    |> Repo.update()
  end

  def expire_stale_leases do
    now = DateTime.utc_now()

    from(el in EnvironmentLease,
      where: el.status == "active" and el.expires_at < ^now
    )
    |> Repo.update_all(set: [status: "expired", updated_at: now])
  end

  def cleanup_expired_workspaces do
    now = DateTime.utc_now()

    from(ew in ExecutionWorkspace,
      where: ew.status == "closed" and ew.cleanup_eligible_at < ^now
    )
    |> Repo.update_all(set: [status: "cleaned_up", updated_at: now])
  end
end
