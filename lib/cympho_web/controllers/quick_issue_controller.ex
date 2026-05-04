defmodule CymphoWeb.QuickIssueController do
  @moduledoc """
  Browser-pipeline endpoint for the global "press C, type title, hit
  Enter" inline issue creation modal. Pulls the current company from
  the session (set by the company switcher) and creates a backlog
  issue with sensible defaults.
  """
  use CymphoWeb, :controller

  alias Cympho.Issues

  def create(conn, %{"title" => title} = params) when is_binary(title) and title != "" do
    company_id = get_session(conn, :company_id)

    if is_nil(company_id) do
      conn
      |> put_flash(:error, "Pick a company before creating an issue.")
      |> redirect(to: ~p"/issues")
    else
      attrs = %{
        "title" => String.trim(title),
        "status" => "backlog",
        "priority" => Map.get(params, "priority", "medium"),
        "company_id" => company_id
      }

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
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Title is required.")
    |> redirect(to: ~p"/issues")
  end
end
