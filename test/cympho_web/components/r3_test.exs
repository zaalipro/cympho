defmodule CymphoWeb.Components.R3Test do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import CymphoWeb.Components.R3

  defp doc(html) when is_binary(html), do: Floki.parse_fragment!(html)
  defp doc(rendered), do: rendered |> rendered_to_string() |> Floki.parse_fragment!()
  defp attr_of(node, name), do: node |> Floki.attribute(name) |> List.first()
  defp classes(node), do: node |> attr_of("class") |> String.split() |> Enum.sort()
  defp elements(node), do: node |> Floki.children() |> Enum.filter(&is_tuple/1)

  describe "next_step" do
    test "a full pair carries exactly one primary" do
      assigns = %{}

      html =
        doc(~H"""
        <.next_step id="ns-">
          <:problem>
            <.problem_card title="Resume Mira" title_id="ns-t">
              <:eyebrow>Next step · Problem</:eyebrow>
              <p class="obj">Mira stopped after 3 failed attempts.</p>
            </.problem_card>
          </:problem>
          <:resolution>
            <.ink_card heading="After you resume" heading_id="ns-i">
              <.consequences rows={[{:done, "Mira can take new work."}]} />
              <.ink_note>To restart NW-10, open it.</.ink_note>
              <.ink_foot verb="resume">
                <:secondary>
                  <.ghost_pill href="/issues/x">Open NW-10</.ghost_pill>
                </:secondary>
                <:primary>
                  <.primary_pill phx-click="resume_agent">Resume Mira</.primary_pill>
                </:primary>
              </.ink_foot>
            </.ink_card>
          </:resolution>
        </.next_step>
        """)

      assert [section] = Floki.find(html, "section.next")
      assert attr_of(section, "aria-labelledby") == "ns-t"
      assert length(Floki.find(html, ".pw")) == 1
      assert [_] = Floki.find(html, "article.paper h2.nt#ns-t")
      assert [_] = Floki.find(html, "article.ink h3.ink-h#ns-i")
      assert Floki.text(Floki.find(html, ".kh")) =~ "to resume"
      assert [pw] = Floki.find(html, "button.pw")
      assert attr_of(pw, "phx-click") == "resume_agent"
      assert Floki.find(html, ".pw .nub svg use") != []
    end

    test "a lone problem card renders without a resolution card" do
      assigns = %{}

      html =
        doc(~H"""
        <.next_step id="ac-">
          <:problem>
            <.problem_card title="Nothing needs you" title_id="ac-t">
              <:eyebrow>All clear</:eyebrow>
            </.problem_card>
          </:problem>
        </.next_step>
        """)

      assert [section] = Floki.find(html, "section.next")
      assert length(elements(section)) == 1
      assert Floki.find(html, ".ink") == []
    end

    test "the resolution card can be the answer form itself" do
      assigns = %{}

      html =
        doc(~H"""
        <.ink_card form="Answer Ravi's question" phx-submit="respond_questions">
          <.ink_note>After you send: Ravi gets your answer.</.ink_note>
        </.ink_card>
        """)

      assert [form] = Floki.find(html, "form.ink")
      assert attr_of(form, "aria-label") == "Answer Ravi's question"
      assert attr_of(form, "phx-submit") == "respond_questions"
      assert Floki.find(html, "h3") == []
    end
  end

  describe "option_rows" do
    defp options(extra \\ %{}) do
      assigns =
        Map.merge(
          %{
            items: [
              %{value: "1", label: "Retry automatically after 3 days"},
              %{value: "2", label: "Email the customer first", sub: "Engineer"},
              %{value: "3", label: "Both", disabled: true}
            ],
            checked: "2"
          },
          extra
        )

      doc(~H"""
      <.option_rows
        name="q1"
        legend="Your answer"
        items={@items}
        checked={@checked}
        describedby="q1-quote"
      />
      """)
    end

    test "each native radio comes right before its label" do
      html = options()
      wrappers = Floki.find(html, ".opt-w")

      for wrapper <- Enum.take(wrappers, 3) do
        [first, second | _] = elements(wrapper)
        assert {"input", _, _} = first
        assert attr_of(first, "type") == "radio"
        assert {"label", _, _} = second
        assert attr_of(second, "for") == attr_of(first, "id")
      end

      assert [fieldset] = Floki.find(html, "fieldset.opts")
      assert attr_of(fieldset, "aria-describedby") == "q1-quote"
      assert Floki.text(Floki.find(html, "legend")) == "Your answer"
      assert Floki.text(Floki.find(html, ".on")) =~ "123"
    end

    test "marks the checked option and renders disabled ones as native disabled inputs" do
      html = options()

      assert [checked] = Floki.find(html, "input.opt-in[checked]")
      assert attr_of(checked, "value") == "2"
      assert [disabled] = Floki.find(html, "input.opt-in[disabled]")
      assert attr_of(disabled, "value") == "3"
      assert Floki.text(Floki.find(html, ".ot-s")) == "Engineer"
    end

    test "offers a write-your-own row whose text box posts as own_response" do
      html = options()

      assert [own] = Floki.find(html, "input.opt-in[value='own']")
      assert attr_of(own, "name") == "q1"
      assert Floki.text(Floki.find(html, "label.opt.own")) =~ "Or write your own answer"
      assert [textarea] = Floki.find(html, ".own-box textarea")
      assert attr_of(textarea, "name") == "own_response"
    end

    test "can leave out the own-answer row" do
      assert Floki.find(own_less(), "textarea") == []
      assert Floki.find(own_less(), "input[value='own']") == []
    end

    defp own_less do
      assigns = %{}

      doc(~H"""
      <.option_rows
        name="who"
        legend="Who retries it"
        items={[%{value: "a", label: "Ravi"}]}
        own={false}
      />
      """)
    end
  end

  describe "page_frame" do
    defp deep(from) do
      assigns = %{from: from}

      doc(~H"""
      <.page_frame
        page="task"
        kind={:deep}
        parent={{"/issues", "Tasks"}}
        current="NW-6"
        current_mono
        from={@from}
      >
        <:head>
          <h1 class="h1 big">Connect Stripe payments</h1>
        </:head>
        <p>body</p>
      </.page_frame>
      """)
    end

    test "a deep page shows the breadcrumb with the current item last" do
      html = deep(nil)

      assert [frame] = Floki.find(html, ".frame")
      assert attr_of(frame, "data-page") == "task"
      assert [header] = Floki.find(html, "header.ctx")
      assert attr_of(header, "data-ctx") == "deep"
      assert [crumb] = Floki.find(html, ~s(nav[aria-label="Breadcrumb"]))
      items = Floki.find(crumb, "li")
      assert length(items) == 2
      assert [current] = Floki.find(List.last(items), "[aria-current='page']")
      assert Floki.text(current) == "NW-6"
      assert classes(current) == ["mono"]
      assert [back] = Floki.find(crumb, "a.back")
      assert attr_of(back, "href") == "/issues"
      assert Floki.find(html, ".tray p") != []
      assert Floki.find(html, "h1.h1.big") != []
    end

    test "Back to the origin appears only when it differs from the parent" do
      assert Floki.find(deep(nil), "a.ret") == []
      assert Floki.find(deep({"/issues", "Tasks"}), "a.ret") == []

      html = deep({"/", "Home"})
      assert [ret] = Floki.find(html, "a.ret")
      assert attr_of(ret, "href") == "/"
      assert Floki.text(ret) =~ "Back to Home"
      assert [pill] = Floki.find(html, "a.from")
      assert Floki.text(pill) =~ "Home"
    end

    test "a deep page keeps Search, New task and Settings for phones" do
      tools = Floki.find(deep(nil), ".ctx-tools")

      assert Floki.find(tools, ~s(a[href="/search"])) != []
      assert Floki.find(tools, ~s(a[href="/issues/new"][data-quick-create-trigger])) != []
      assert Floki.find(tools, ~s(a[href="/settings"])) != []
    end

    test "a root page shows its H1, aside and end controls" do
      assigns = %{}

      html =
        doc(~H"""
        <.page_frame page="home" title="Home" tray_class="lower">
          <:aside>Wednesday 21 Oct</:aside>
          <:header_end><a href="/agents/new">Hire</a></:header_end>
          <p>body</p>
        </.page_frame>
        """)

      assert [header] = Floki.find(html, "header.ctx")
      assert attr_of(header, "data-ctx") == "root"
      assert Floki.text(Floki.find(html, "h1.h1")) == "Home"
      assert Floki.text(Floki.find(html, "p.h1-aside")) =~ "Wednesday 21 Oct"
      assert Floki.find(html, ".ctx-end a[href='/agents/new']") != []
      assert Floki.find(html, ".ctx-tools") == []
      assert [tray] = Floki.find(html, ".tray")
      assert classes(tray) == ["lower", "tray"]
    end
  end

  describe "tick_meter" do
    test "draws the 60-tick scale with the fill and the 80% warning mark" do
      html = doc(render_component(&tick_meter/1, percent: 62))

      assert [tk] = Floki.find(html, ".tk")
      assert attr_of(tk, "aria-hidden") == "true"
      assert attr_of(tk, "data-ticks") == "60"
      assert [fill] = Floki.find(html, ".tk-fill")
      assert attr_of(fill, "style") =~ "width:62%"
      assert attr_of(fill, "style") =~ "calc(100% / 37.2)"
      assert [warn] = Floki.find(html, ".tk-warn")
      assert attr_of(warn, "style") =~ "left:80%"
      assert Floki.text(Floki.find(html, ".tk-legend .w")) == "80%"
    end

    test "clamps the fill to the scale" do
      html = doc(render_component(&tick_meter/1, percent: 140, class: "full"))

      assert attr_of(hd(Floki.find(html, ".tk-fill")), "style") =~ "width:100%"
      assert classes(hd(Floki.find(html, ".tk"))) == ["full", "tk"]
    end
  end

  describe "run_bars" do
    test "bar widths follow each run's length on a shared axis" do
      t0 = ~U[2026-10-21 01:58:00Z]

      runs = [
        %{started_at: t0, completed_at: DateTime.add(t0, 120), status: "failed"},
        %{started_at: t0, completed_at: DateTime.add(t0, 1800), status: "timed_out"}
      ]

      html = doc(render_component(&run_bars/1, runs: runs, label: "Mira's last runs"))

      assert [figure] = Floki.find(html, "figure.rb")
      assert attr_of(figure, "aria-label") == "Mira's last runs"
      [short, long] = Floki.find(html, ".rb-bar")
      assert attr_of(short, "style") =~ "width:6.67%"
      assert attr_of(long, "style") =~ "width:100%"
      assert attr_of(short, "class") =~ "hatch"
      assert Floki.text(Floki.find(html, ".rb-v")) =~ "Failed"
      assert Floki.text(Floki.find(html, ".rb-v")) =~ "Timed out"
      assert Floki.text(Floki.find(html, ".rb-t")) =~ "01:58"
      assert Floki.text(Floki.find(html, ".rb-axis")) =~ "30 min"
    end

    test "a minimum axis keeps short runs short" do
      t0 = ~U[2026-10-21 01:58:00Z]
      runs = [%{started_at: t0, completed_at: DateTime.add(t0, 120), status: "completed"}]

      html = doc(render_component(&run_bars/1, runs: runs, label: "Runs", axis_min: 30))

      assert attr_of(hd(Floki.find(html, ".rb-bar")), "style") =~ "width:6.67%"
      refute attr_of(hd(Floki.find(html, ".rb-bar")), "class") =~ "hatch"
    end
  end

  describe "status_glyph" do
    test "each kind draws its own shape and colour; only Working spins" do
      for {kind, symbol, colour} <- [
            {:working, "#g-work", "c-work"},
            {:waiting, "#g-wait", "c-wait"},
            {:stopped, "#g-stop", "c-stop"},
            {:done, "#g-done", "c-done"},
            {:idle, "#g-idle", "c-idle"}
          ] do
        html = doc(render_component(&status_glyph/1, kind: kind))
        [svg] = Floki.find(html, "svg")
        assert attr_of(svg, "class") =~ colour
        assert attr_of(svg, "aria-hidden") == "true"
        assert attr_of(hd(Floki.find(svg, "use")), "href") == symbol
        assert attr_of(svg, "class") =~ "spin" == (kind == :working)
      end
    end

    test "status_word pairs the glyph with its word" do
      html = doc(render_component(&status_word/1, kind: :stopped, word: "Paused"))
      assert Floki.text(html) =~ "Paused"
      assert Floki.find(html, "svg.g") != []
    end
  end

  describe "segmented" do
    test "marks exactly one segment current" do
      assigns = %{}

      html =
        doc(~H"""
        <.segmented label="Show">
          <:item patch="/inbox" current>All</:item>
          <:item patch="/inbox?kind=problem">Problems</:item>
          <:item patch="/inbox?kind=question">Questions</:item>
        </.segmented>
        """)

      assert [nav] = Floki.find(html, "nav.seg")
      assert attr_of(nav, "aria-label") == "Show"
      assert length(Floki.find(nav, "a")) == 3
      assert [current] = Floki.find(nav, "a[aria-current]")
      assert attr_of(current, "aria-current") == "page"
      assert String.trim(Floki.text(current)) == "All"
    end
  end

  describe "rows, cards and smaller parts" do
    test "needs_row covers the row with one secondary verb described by its title and meta" do
      assigns = %{}

      html =
        doc(~H"""
        <ul class="rows">
          <.needs_row
            id="ny1"
            kind={:question}
            icon="i-question"
            title="Answer Ravi's question"
            verb="Answer"
            navigate="/issues/1"
          >
            Question · NW-6
          </.needs_row>
        </ul>
        """)

      assert [row] = Floki.find(html, "li.row")
      assert classes(hd(Floki.find(row, ".kt"))) == ["kt", "q"]
      assert [go] = Floki.find(row, "a.pl.go")
      assert attr_of(go, "aria-describedby") == "ny1 ny1m"
      assert attr_of(go, "href") == "/issues/1"
      assert Floki.text(Floki.find(row, "#ny1")) == "Answer Ravi's question"
      assert Floki.text(Floki.find(row, "#ny1m")) =~ "NW-6"
    end

    test "band_card labels its section by the heading" do
      assigns = %{}

      html =
        doc(~H"""
        <.band_card id="ny-t" title="Needs you">
          <:header_end><.text_link navigate="/inbox">Open Inbox</.text_link></:header_end>
          <p>rows</p>
        </.band_card>
        """)

      assert [section] = Floki.find(html, "section.card")
      assert attr_of(section, "aria-labelledby") == "ny-t"
      assert [_] = Floki.find(html, ".card-h.band h2#ny-t")
      assert Floki.find(html, "a.lnk svg") != []
    end

    test "kv_list renders terms and values" do
      assigns = %{}

      html =
        doc(~H"""
        <.kv_list tight>
          <:item term="Project">Invoicing app</:item>
          <:item term="Created">Mon 19 Oct</:item>
        </.kv_list>
        """)

      assert [dl] = Floki.find(html, "dl")
      assert classes(dl) == ["kv", "tight"]
      assert Enum.map(Floki.find(dl, "dt"), &Floki.text/1) == ["Project", "Created"]
    end

    test "object_tile draws a document or code file and links its title" do
      html =
        doc(
          render_component(&object_tile/1,
            kind: :code,
            title: "PR #44",
            sub: "Pull request",
            href: "https://example.test/pr/44"
          )
        )

      assert Floki.find(html, ".objt svg.file") != []
      assert [link] = Floki.find(html, "a.objt-t")
      assert attr_of(link, "href") == "https://example.test/pr/44"
      assert Floki.text(Floki.find(html, ".objt-s")) == "Pull request"
    end

    test "team_row shows the agent, its status word and the for-you chip" do
      html =
        doc(
          render_component(&team_row/1,
            name: "Mira",
            href: "/agents/1",
            kind: :stopped,
            word: "Paused",
            for_you: 1,
            pin: true
          )
        )

      assert [li] = Floki.find(html, "li.pin")
      assert Floki.text(Floki.find(li, ".m-name")) == "Mira"
      assert classes(hd(Floki.find(li, ".m-word"))) == ["c-stop", "m-word"]
      assert Floki.text(Floki.find(li, ".fy")) == "1 for you"

      quiet =
        doc(
          render_component(&team_row/1, name: "Ada", href: "/agents/2", kind: :idle, word: "Idle")
        )

      assert Floki.find(quiet, "li.pin") == []
      assert Floki.find(quiet, ".fy") == []
    end

    test "now_capsule animates only while working" do
      assigns = %{}

      working =
        doc(~H"""
        <.now_capsule state={:working}>Theo is reviewing NW-9<:sub>28 min</:sub></.now_capsule>
        """)

      waiting =
        doc(~H"""
        <.now_capsule state={:waiting}>Ravi is waiting for your answer</.now_capsule>
        """)

      assert classes(hd(Floki.find(working, ".now"))) == ["now", "working"]
      assert classes(hd(Floki.find(waiting, ".now"))) == ["now", "waiting"]
      assert Floki.text(Floki.find(working, "small")) == "28 min"
    end

    test "search_capsule, composer, chip and quiet_empty render their r3 anatomy" do
      assigns = %{}

      html =
        doc(~H"""
        <div>
          <.search_capsule label="Search tasks" placeholder="Search" />
          <.composer
            id="reply"
            label="Reply to Ravi"
            help="Sending asks Ravi to read it now."
            button="Send reply"
            phx-submit="add_comment"
          />
          <.chip tone="st-wait"><.status_word kind={:waiting} word="Waiting on you" /></.chip>
          <.quiet_empty heading="Working on" title="No open tasks">Last: NW-10</.quiet_empty>
        </div>
        """)

      assert [input] = Floki.find(html, "label.search input[type='search']")
      assert attr_of(input, "name") == "q"
      assert Floki.text(Floki.find(html, "label.search .sr")) == "Search tasks"
      assert [form] = Floki.find(html, "form.composer")
      assert attr_of(form, "phx-submit") == "add_comment"
      assert attr_of(hd(Floki.find(form, "label")), "for") == "reply"
      assert Floki.find(form, "button.pl[type='submit']") != []
      assert classes(hd(Floki.find(html, "button.chip"))) == ["chip", "st-wait"]
      assert Floki.text(Floki.find(html, ".gl-big")) == "No open tasks"
    end

    test "the sprite defines every icon the shell uses" do
      html = doc(render_component(&r3_sprite/1, %{}))

      for id <-
            ~w(i-home i-inbox i-tasks i-team i-spend i-settings i-search i-plus i-chev-down i-chev-updown g-work g-wait g-stop g-done g-idle) do
        assert Floki.find(html, "symbol##{id}") != [], "missing #{id}"
      end
    end
  end
end
