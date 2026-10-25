defmodule CymphoWeb.MobileShellTest do
  use ExUnit.Case, async: true

  @root_layout "lib/cympho_web/controllers/layouts/root.html.heex"
  @app_css "assets/css/app.css"
  @r3_css "assets/css/r3.css"
  @kanban_board "lib/cympho_web/live/kanban_live/index.html.heex"
  @issue_new "lib/cympho_web/live/issue_live/new.html.heex"
  @agent_new "lib/cympho_web/live/agent_live/new.html.heex"

  test "application shell uses dynamic viewport units instead of fixed screen height" do
    layout = File.read!(@root_layout)

    assert layout =~ "h-[100dvh]"
    assert layout =~ "min-h-[100svh]"
    assert layout =~ "max-h-[calc(100dvh-"
    refute layout =~ ~s(class="h-screen)
  end

  # r3: one Main nav serves the rail and the phone tab bar (n2), so the safe
  # area moved from the old #mobile-nav markup into the tab bar's CSS offset.
  test "mobile content, navigation, dialogs, and toasts account for safe areas" do
    layout = File.read!(@root_layout)
    css = File.read!(@app_css)
    r3 = File.read!(@r3_css)

    assert layout =~ "mobile-shell-content"
    assert layout =~ "safe-area-dialog"
    assert layout =~ "safe-area-toast"
    refute layout =~ ~s(id="mobile-nav")
    assert r3 =~ "bottom:calc(8px + env(safe-area-inset-bottom, 0px))"

    for inset <- ["top", "right", "bottom", "left"] do
      assert css =~ "safe-area-inset-#{inset}"
    end

    assert css =~ "--mobile-header-height: 60px"
    # The tab bar's top edge (measured at 390x844: 770 = 844 - 74).
    assert css =~ "--mobile-nav-height: 74px"
    assert css =~ "--mobile-nav-offset: calc("
    assert css =~ "--mobile-shell-bottom: calc(4rem + env(safe-area-inset-bottom, 0px))"
    assert css =~ "padding-bottom: var(--mobile-shell-bottom)"
    assert css =~ "scroll-padding-bottom: var(--mobile-shell-bottom)"
  end

  # r3: the phone tab bar is the Main nav itself; Tasks owns list and board.
  test "mobile navigation uses one Tasks destination for list and board" do
    layout = File.read!(@root_layout)

    assert length(String.split(layout, "<.nav_rail")) == 2

    [tasks] = Enum.filter(CymphoWeb.Components.NavRail.destinations(), &(&1.label == "Tasks"))
    assert tasks.to == "/issues"
    assert "/kanban" in tasks.roots
    refute Enum.any?(CymphoWeb.Components.NavRail.destinations(), &(&1.to == "/kanban"))
  end

  test "the board never uses a fixed screen height" do
    board = File.read!(@kanban_board)

    # r3: the board scrolls with the page column (no fixed board height); it
    # must still never use 100vh or h-screen. The orphaned .mobile-board-height
    # rule was removed with its CSS assertions (work track FR3).
    refute board =~ "100vh"
    refute board =~ "h-screen"
  end

  # r3: #main-content (.col) pads 104 px at the bottom on phones, and a sticky
  # inset counts from the scroller's padding edge (measured in Chromium: the
  # bare offset left the bar 104 px above the tab bar; w3c/csswg-drafts#3352),
  # so the inset is the tab bar's top edge minus that padding.
  test "sticky CTAs clear fixed mobile bottom nav via nav+safe-area offset" do
    issue_new = File.read!(@issue_new)
    agent_new = File.read!(@agent_new)
    css = File.read!(@app_css)
    r3 = File.read!(@r3_css)

    assert css =~ "bottom: calc(var(--mobile-nav-offset) - 104px)"
    assert r3 =~ ".cy-r3 .col{padding:0 6px 104px;"

    assert issue_new =~ "sticky-above-mobile-nav"
    assert issue_new =~ "sticky"
    refute issue_new =~ "sticky bottom-0"

    assert agent_new =~ "sticky-above-mobile-nav"
    assert agent_new =~ ~s(data-testid="new-agent-form-actions")
    assert agent_new =~ "sticky"
    refute agent_new =~ "sticky bottom-0"

    assert css =~ ".sticky-above-mobile-nav"
  end

  # Every `@media (max-width:640px)` block of a stylesheet, comments stripped.
  defp phone_css(path) do
    css = path |> File.read!() |> then(&Regex.replace(~r{/\*.*?\*/}s, &1, ""))

    ~r/@media \(max-width: ?640px\) ?\{/
    |> Regex.split(css)
    |> tl()
    |> Enum.map_join("\n", &take_block(&1, 1, []))
  end

  defp take_block(<<"}", _::binary>>, 1, acc), do: acc |> Enum.reverse() |> to_string()
  defp take_block(<<"}", rest::binary>>, d, acc), do: take_block(rest, d - 1, ["}" | acc])
  defp take_block(<<"{", rest::binary>>, d, acc), do: take_block(rest, d + 1, ["{" | acc])
  defp take_block(<<c::utf8, rest::binary>>, d, acc), do: take_block(rest, d, [<<c::utf8>> | acc])

  # B13: iOS zooms into a focused field whose text is under 16px.
  test "phone form fields are 16px, desktop sizes stay" do
    phone = phone_css(@r3_css)

    assert phone =~
             ".cy-r3 :is(input,textarea,select),.cy-r3 .search input,.cy-r3 .composer textarea{font-size:16px}"

    assert phone_css("assets/css/r3-pages/onboarding.css") =~
             ~s|.cy-r3 [data-page="onboarding"] :is(.fld input,.fld input.mono,.fld textarea,.ob-role select,.ob-role input){font-size:16px}|

    r3 = File.read!(@r3_css)
    assert r3 =~ "background:transparent;outline:none;font-size:13px;color:var(--ink)}"
    assert r3 =~ "color:var(--ink);resize:vertical;font-size:14px;line-height:20px}"
  end

  # C3: a sticky header sticks at the scroller's content edge, under .col's top
  # padding (w3c/csswg-drafts#3352), and its corners are rounded, so scrolled
  # content showed above it and in its corners. Its layers redraw the frame's top.
  test "the stuck context header covers the strip above it and its corners" do
    r3 = File.read!(@r3_css)

    assert r3 =~
             ~s|.cy-r3 .ctx[data-ctx]::before,.cy-r3 .ctx[data-ctx]::after{content:"";position:absolute;z-index:-1;left:-10px;right:-10px;pointer-events:none}|

    assert r3 =~
             ".cy-r3 .ctx[data-ctx]::before{top:-12px;height:calc(12px + var(--r-frame));background:var(--page)}"

    assert r3 =~
             ".cy-r3 .ctx[data-ctx]::after{top:0;bottom:0;border-radius:var(--r-frame) var(--r-frame) 0 0;background:var(--frame)}"

    phone = phone_css(@r3_css)

    assert phone =~
             ".cy-r3 .ctx[data-ctx]::before,.cy-r3 .ctx[data-ctx]::after{left:-6px;right:-6px}"

    assert phone =~ ".cy-r3 .ctx[data-ctx]::before{height:36px}"
    assert phone =~ ".cy-r3 .ctx[data-ctx]::after{border-radius:24px 24px 0 0}"

    assert phone =~
             ~s|.cy-r3 .ctx[data-ctx="root"]::before,.cy-r3 .ctx[data-ctx="root"]::after{content:none}|
  end

  # C3: toasts sat over the header's end (the Inbox filter, "Back to Home").
  # On phones the band between the Next step's primary (ends by y 729 at
  # 390x844) and the tab bar (770) is the clear spot: a 36 px toast 4 px above it.
  test "toasts sit at the bottom, in the band above the phone tab bar, and never take a tap" do
    css = File.read!(@app_css)
    [container] = Regex.run(~r/\.safe-area-toast \{[^}]*\}/, css)

    refute container =~ "top:"
    assert container =~ "bottom: calc(1rem + env(safe-area-inset-bottom, 0px));"
    assert container =~ "right: calc(1rem + env(safe-area-inset-right, 0px));"

    phone = phone_css(@app_css)
    assert phone =~ "bottom: calc(var(--mobile-nav-offset) + 4px);"
    assert phone =~ "padding: 8px 14px;"

    # Up to five toasts stacked up from the band over the Next step's primary
    # ("Send answer", "Change limit"): a phone shows only the newest, one at a
    # time, as Material's snackbar does.
    assert phone =~ ".safe-area-toast .toast:not(:last-child) {\n    display: none;\n  }"

    [toast] = Regex.run(~r/\n\.toast \{[^}]*\}/, css)
    assert toast =~ "pointer-events: none;"
  end

  # C8: four equal shares of the phone row were narrower than "Created by me";
  # `flex:auto` still let a tab shrink under its label, so it wrapped at 320 px.
  test "Mine's tabs never shrink under their labels on phones; a narrow row scrolls" do
    phone = phone_css("assets/css/r3-pages/work.css")

    assert phone =~ ~s|.cy-r3 [data-page="mine"] .seg{overflow-x:auto;scrollbar-width:none}|
    assert phone =~ ~s|.cy-r3 [data-page="mine"] .seg a{flex:1 0 auto;white-space:nowrap}|
    refute phone =~ ~s|.cy-r3 [data-page="mine"] .seg a{flex:auto}|
  end
end
