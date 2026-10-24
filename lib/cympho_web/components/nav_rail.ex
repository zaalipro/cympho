defmodule CymphoWeb.Components.NavRail do
  @moduledoc """
  The n2 Main navigation: six destinations in one order (N1), each with its
  pages (N2), the Inbox count (N6) and the orange current dot. The same
  `<nav aria-label="Main">` is the phone tab bar (r3.css phone block).

  The root layout is not re-rendered on live navigation, so every
  destination's pages are always rendered and CSS shows them only under the
  current one; `highlightActiveNav()` in app.js re-marks the current
  destination from the same table, rendered into `data-nav-*` attributes.
  """
  use Phoenix.Component

  import CymphoWeb.Components.R3, only: [r3_icon: 1]

  # Each destination: its link, the paths that make it current (`matches`,
  # prefix match), the root pages where it is aria-current="page" rather than
  # "true" (`roots`, exact; a trailing /* matches the whole subtree), and its
  # pages. Advanced pages carry ui-advanced-only.
  @destinations [
    %{
      key: "home",
      to: "/",
      label: "Home",
      icon: "i-home",
      matches: ~w(/ /dashboard /activity /overview),
      roots: ~w(/ /dashboard),
      kids: [{"/activity", "Activity", :simple}, {"/overview", "Compare companies", :multi}]
    },
    %{
      key: "inbox",
      to: "/inbox",
      label: "Inbox",
      icon: "i-inbox",
      matches: ~w(/inbox /approvals /board-approvals /reviews),
      roots: ~w(/inbox),
      kids: [
        {"/inbox", "Needs you", :simple},
        {"/approvals", "Approval history", :simple},
        {"/reviews", "Reviews", :advanced}
      ]
    },
    %{
      key: "tasks",
      to: "/issues",
      label: "Tasks",
      icon: "i-tasks",
      matches:
        ~w(/issues /kanban /my-issues /projects /goals /routines /launch-items /workspaces /workspace),
      roots: ~w(/issues /kanban),
      kids: [
        {"/issues", "All tasks", :simple},
        {"/projects", "Projects", :simple},
        {"/goals", "Goals", :simple},
        {"/routines", "Repeating tasks", :simple},
        {"/launch-items", "Launch checklist", :simple},
        {"/workspaces", "Work files", :advanced}
      ]
    },
    %{
      key: "team",
      to: "/agents",
      label: "Team",
      icon: "i-team",
      matches: ~w(/agents /org-chart /skills /operations /tool-call-traces),
      roots: ~w(/agents),
      kids: [
        {"/agents", "People", :simple},
        {"/org-chart", "Org chart", :simple},
        {"/skills", "Skills", :advanced},
        {"/operations", "Health", :advanced},
        {"/tool-call-traces", "Step log", :advanced}
      ]
    },
    %{
      key: "spending",
      to: "/costs",
      label: "Spending",
      icon: "i-spend",
      matches: ~w(/costs /budgets),
      roots: ~w(/costs),
      kids: [{"/budgets", "Spending limit", :simple}]
    },
    %{
      key: "settings",
      to: "/settings",
      label: "Settings",
      icon: "i-settings",
      matches: ~w(/settings /labels /companies /plugins),
      roots: ~w(/settings /settings/*),
      kids: []
    }
  ]

  # A page whose other views keep it current: Board and Mine are views of the
  # one Tasks page (List | Board, the Mine chip), so All tasks stays marked.
  @kid_views %{"/issues" => ~w(/kanban /my-issues)}

  @doc "The destination table (single source for the server render and app.js)."
  def destinations, do: @destinations

  @doc """
  The current destination for a path: `{key, "page" | "true"}`, or nil when the
  path belongs to no destination (Search, Docs).
  """
  def current(path) when is_binary(path) do
    Enum.find_value(@destinations, fn dest ->
      if Enum.any?(dest.matches, &prefix_match?(path, &1)) do
        {dest.key, if(Enum.any?(dest.roots, &root_match?(path, &1)), do: "page", else: "true")}
      end
    end)
  end

  def current(_path), do: nil

  attr :current_path, :string, required: true
  attr :inbox_count, :integer, default: 0
  attr :company_count, :integer, default: 0
  attr :rest, :global

  def nav_rail(assigns) do
    current = current(assigns.current_path)

    destinations =
      Enum.map(@destinations, fn dest ->
        state =
          case current do
            {key, state} when key == dest.key -> state
            _ -> nil
          end

        kids =
          Enum.reject(dest.kids, fn {_, _, kind} ->
            kind == :multi and assigns.company_count < 2
          end)

        %{dest | kids: kids} |> Map.put(:state, state)
      end)

    count = assigns.inbox_count |> max(0) |> min(99)

    assigns =
      assigns
      |> assign(:destinations, destinations)
      |> assign(:count, count)

    ~H"""
    <nav class="dest" aria-label="Main" data-ui-complex-page {@rest}>
      <ul>
        <li :for={dest <- @destinations} class={dest.key == "settings" && "li-settings"}>
          <.dest_link dest={dest} count={@count} />
          <ul :if={dest.kids != []} class="kids">
            <li :for={{href, label, kind} <- dest.kids} class={kind != :simple && "ui-advanced-only"}>
              <.link navigate={href} {kid_attrs(@current_path, href)}>{label}</.link>
            </li>
          </ul>
        </li>
      </ul>
    </nav>
    """
  end

  attr :dest, :map, required: true
  attr :count, :integer, required: true

  # Settings is a plain link: /settings is the controller redirect that picks
  # the Settings landing page in one place.
  defp dest_link(%{dest: %{key: "settings"}} = assigns) do
    ~H"""
    <a
      class="d"
      href={@dest.to}
      aria-current={@dest.state}
      data-nav-matches={Enum.join(@dest.matches, ",")}
      data-nav-roots={Enum.join(@dest.roots, ",")}
    >
      <.r3_icon name={@dest.icon} class="ico" /><span class="lbl">{@dest.label}</span><span
        class="sel"
        aria-hidden="true"
      ></span>
    </a>
    """
  end

  defp dest_link(assigns) do
    ~H"""
    <.link
      class="d"
      navigate={@dest.to}
      aria-current={@dest.state}
      data-nav-matches={Enum.join(@dest.matches, ",")}
      data-nav-roots={Enum.join(@dest.roots, ",")}
    >
      <.r3_icon name={@dest.icon} class="ico" /><span class="lbl">{@dest.label}</span>
      <.inbox_count
        :if={@dest.key == "inbox"}
        count={@count}
      /><span class="sel" aria-hidden="true"></span>
    </.link>
    """
  end

  attr :count, :integer, required: true

  # The one badge (N6). The node is always present so the `nav_badges` push
  # can update it; at zero it is hidden. The number carries the test id.
  defp inbox_count(assigns) do
    ~H"""
    <span
      class={["count", @count == 0 && "hidden"]}
      data-nav-badge="inbox"
      data-count={@count}
      aria-hidden={if(@count > 0, do: "false", else: "true")}
    >
      <span data-badge-num data-testid={@count > 0 && "nav-badge-inbox"}>
        {if @count > 0, do: @count}
      </span>
      <span class="sr"> need you</span>
    </span>
    """
  end

  # A destination's page: "page" on its own path and its views, "true" on the
  # pages below it. The views go to app.js as data-nav-views (nil attrs are
  # not rendered).
  defp kid_attrs(path, href) do
    views = Map.get(@kid_views, href, [])

    state =
      cond do
        path == href or path in views -> "page"
        prefix_match?(path, href) -> "true"
        true -> nil
      end

    ["aria-current": state, "data-nav-views": views != [] && Enum.join(views, ",")]
  end

  defp prefix_match?(path, "/"), do: path == "/"

  defp prefix_match?(path, pattern),
    do: path == pattern or String.starts_with?(path, pattern <> "/")

  defp root_match?(path, pattern) do
    if String.ends_with?(pattern, "/*"),
      do: String.starts_with?(path, String.trim_trailing(pattern, "*")),
      else: path == pattern
  end
end
