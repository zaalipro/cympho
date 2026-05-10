defmodule CymphoWeb.QuickIssueController do
  @moduledoc """
  Browser-pipeline endpoint for the global "press C, type title, hit
  Enter" inline issue creation modal. Pulls the current company from
  the session (set by the company switcher) and creates a scoped issue
  with the selected project, assignee, and status.
  """
  use CymphoWeb, :controller

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Projects

  def create(conn, %{"title" => title} = params) when is_binary(title) and title != "" do
    if is_nil(get_session(conn, :user_id)) do
      conn
      |> put_flash(:error, "Sign in before creating an issue.")
      |> redirect(to: ~p"/login")
    else
      create_for_current_company(conn, title, params)
    end
  end

  def create(conn, _params) do
    if is_nil(get_session(conn, :user_id)) do
      conn
      |> put_flash(:error, "Sign in before creating an issue.")
      |> redirect(to: ~p"/login")
    else
      conn
      |> put_flash(:error, "Title is required.")
      |> redirect(to: ~p"/issues")
    end
  end

  defp create_for_current_company(conn, title, params) do
    case current_company_id(conn) do
      nil ->
        conn
        |> put_flash(:error, "Pick a company before creating an issue.")
        |> redirect(to: ~p"/issues")

      company_id ->
        case quick_issue_attrs(conn, company_id, title, params) do
          {:ok, attrs} ->
            case Issues.create_issue(attrs) do
              {:ok, issue} ->
                conn
                |> put_flash(:info, "Created \"#{issue.title}\"")
                |> redirect(to: ~p"/issues/#{issue.id}")

              {:error, _changeset} ->
                conn
                |> put_flash(:error, "Could not create issue.")
                |> redirect(to: ~p"/issues")
            end

          {:error, message} ->
            conn
            |> put_flash(:error, message)
            |> redirect(to: ~p"/issues")
        end
    end
  end

  defp quick_issue_attrs(conn, company_id, title, params) do
    with {:ok, status} <- validate_status(Map.get(params, "status", "todo")),
         {:ok, priority} <- validate_priority(Map.get(params, "priority", "medium")),
         {:ok, project_id} <- validate_project(company_id, Map.get(params, "project_id")),
         {:ok, assignee} <- validate_assignee(company_id, Map.get(params, "assignee_id")) do
      attrs =
        %{
          "title" => String.trim(title),
          "status" => status,
          "priority" => priority,
          "company_id" => company_id
        }
        |> put_optional("project_id", project_id)
        |> put_assignee(assignee)
        |> put_created_by(conn.assigns[:current_user])

      {:ok, attrs}
    end
  end

  defp validate_status(status) when is_binary(status) do
    if status in Enum.map(Issue.status_options(), &to_string/1) do
      {:ok, status}
    else
      {:error, "Choose a valid status."}
    end
  end

  defp validate_status(_status), do: {:error, "Choose a valid status."}

  defp validate_priority(priority) when is_binary(priority) do
    if priority in Enum.map(Issue.priority_options(), &to_string/1) do
      {:ok, priority}
    else
      {:error, "Choose a valid priority."}
    end
  end

  defp validate_priority(_priority), do: {:error, "Choose a valid priority."}

  defp validate_project(_company_id, project_id) when project_id in [nil, ""], do: {:ok, nil}

  defp validate_project(company_id, project_id) do
    case Projects.get_company_project(company_id, project_id) do
      {:ok, _project} -> {:ok, project_id}
      {:error, :not_found} -> {:error, "Choose a project from this company."}
    end
  end

  defp validate_assignee(_company_id, assignee_id) when assignee_id in [nil, ""], do: {:ok, nil}

  defp validate_assignee(company_id, assignee_id) do
    case Agents.get_company_agent(company_id, assignee_id) do
      {:ok, agent} -> {:ok, agent}
      {:error, :not_found} -> {:error, "Choose an assignee from this company."}
    end
  end

  defp put_optional(attrs, _key, nil), do: attrs
  defp put_optional(attrs, key, value), do: Map.put(attrs, key, value)

  defp put_assignee(attrs, nil), do: attrs

  defp put_assignee(attrs, agent) do
    attrs
    |> Map.put("assignee_id", agent.id)
    |> Map.put("assigned_role", to_string(agent.role))
  end

  defp put_created_by(attrs, %{id: user_id}), do: Map.put(attrs, "created_by_user_id", user_id)
  defp put_created_by(attrs, _user), do: attrs

  defp current_company_id(conn) do
    company_id = get_session(conn, :company_id)
    user = conn.assigns[:current_user]

    if (is_binary(company_id) and user) && Companies.has_access?(user.id, company_id) do
      company_id
    end
  end
end
