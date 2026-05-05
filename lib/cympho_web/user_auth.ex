defmodule CymphoWeb.UserAuth do
  @moduledoc """
  Authentication and company context for LiveViews.

  Provides an on_mount hook that:
  - Loads the current user from session
  - Determines the current company from session or user default
  - Falls back to first membership company if needed
  - Assigns :current_user, :user_companies, :current_company to socket
  """

  import Phoenix.Component, only: [assign: 3]
  import Ecto.Query
  alias Cympho.Users

  def on_mount(:default, _params, session, socket) do
    socket =
      socket
      |> assign_current_user(session)
      |> assign_user_companies()
      |> assign_current_company(session)
      |> assign_sidebar_data()

    {:cont, socket}
  end

  defp assign_sidebar_data(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        socket
        |> assign(:nav_projects, Cympho.Projects.list_for_sidebar(company_id))
        |> assign(:nav_agents, Cympho.Agents.list_for_sidebar(company_id))
        |> assign(:nav_inbox_count, Cympho.Inbox.unread_count_for_company(company_id))

      _ ->
        socket
        |> assign(:nav_projects, [])
        |> assign(:nav_agents, [])
        |> assign(:nav_inbox_count, 0)
    end
  end

  defp assign_current_user(socket, session) do
    case session["user_id"] do
      nil ->
        # Guest user
        assign(socket, :current_user, nil)

      user_id ->
        case Users.get_user(user_id) do
          {:ok, user} ->
            # Store lightweight map instead of full Ecto struct to avoid
            # Jason.Encoder errors in LiveView test mode
            user_map = %{
              id: user.id,
              email: user.email,
              name: user.name,
              company_id: user.company_id
            }

            assign(socket, :current_user, user_map)

          {:error, :not_found} ->
            # Invalid user ID in session - treat as guest
            assign(socket, :current_user, nil)
        end
    end
  end

  defp assign_user_companies(socket) do
    user = socket.assigns[:current_user]

    companies =
      if is_nil(user) do
        []
      else
        query =
          from(m in Cympho.Companies.CompanyMembership,
            where: m.user_id == ^user.id,
            order_by: [asc: m.inserted_at],
            preload: :company
          )

        Cympho.Repo.all(query)
        |> Enum.map(& &1.company)
        |> Enum.map(fn c -> %{id: c.id, name: c.name, logo_url: c.logo_url} end)
      end

    assign(socket, :user_companies, companies)
  end

  defp assign_current_company(socket, session) do
    user = socket.assigns[:current_user]
    companies = socket.assigns[:user_companies]

    company =
      cond do
        is_nil(user) ->
          List.first(companies)

        # Try session company_id first
        session["company_id"] ->
          session_company =
            companies
            |> Enum.find(fn c -> c.id == session["company_id"] end)

          session_company || fallback_company(user, companies)

        # Try user's default company_id
        user.company_id ->
          user_company =
            companies
            |> Enum.find(fn c -> c.id == user.company_id end)

          user_company || fallback_company(user, companies)

        # Fallback to first membership company
        true ->
          List.first(companies)
      end

    assign(socket, :current_company, company)
  end

  defp fallback_company(_user, companies) do
    # If the session company or user default company is not in the user's memberships,
    # fall back to the first company in their memberships
    List.first(companies)
  end
end
