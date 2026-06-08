defmodule CymphoWeb.LegacyRedirectController do
  @moduledoc """
  Redirects pre-Settings-hub URLs to their new `/settings/*` homes, so old
  bookmarks and deep links keep resolving after the consolidation. Wired up in
  the router after the `live_session` blocks.
  """
  use CymphoWeb, :controller

  def settings(conn, _params), do: redirect(conn, to: ~p"/settings/profile")
  def adapters(conn, _params), do: redirect(conn, to: ~p"/settings/adapters")
  def adapter(conn, %{"key" => key}), do: redirect(conn, to: ~p"/settings/adapters/#{key}")
  # Old links carried the company in the path; switch to it (membership-checked
  # by CompanySwitcherController) before landing on the current-company-scoped
  # settings page, so the redirect doesn't silently swap which company is shown.
  def secrets(conn, %{"id" => id}),
    do: redirect(conn, to: ~p"/switch-company/#{id}?#{[return_to: "/settings/secrets"]}")

  def secrets(conn, _params), do: redirect(conn, to: ~p"/settings/secrets")
  def policies(conn, _params), do: redirect(conn, to: ~p"/settings/policies")
  def policy_new(conn, _params), do: redirect(conn, to: ~p"/settings/policies/new")
  def policy(conn, %{"id" => id}), do: redirect(conn, to: ~p"/settings/policies/#{id}")
  def policy_edit(conn, %{"id" => id}), do: redirect(conn, to: ~p"/settings/policies/#{id}/edit")
  def audit(conn, _params), do: redirect(conn, to: ~p"/settings/audit")
end
