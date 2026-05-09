defmodule CymphoWeb.QuickIssueController do
  @moduledoc """
  Browser-pipeline endpoint for the global "press C, type title, hit
  Enter" inline issue creation modal. Pulls the current company from
  the session (set by the company switcher) and creates a backlog
  issue with sensible defaults.
  """
  use CymphoWeb, :controller

  alias Cympho.Companies
  alias Cympho.Issues

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

  defp current_company_id(conn) do
    company_id = get_session(conn, :company_id)
    user = conn.assigns[:current_user]

    if (is_binary(company_id) and user) && Companies.has_access?(user.id, company_id) do
      company_id
    end
  end
end
