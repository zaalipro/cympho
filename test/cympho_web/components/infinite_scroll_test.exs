defmodule CymphoWeb.Components.InfiniteScrollTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import CymphoWeb.Components

  test "renders the stream container, sentinel, and empty slot when has_more" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.infinite_scroll id="things" has_more={true}>
        <:empty>NOTHING-HERE</:empty>
        <div id="things-1">ROW-ONE</div>
      </.infinite_scroll>
      """)

    assert html =~ ~s(id="things-list")
    assert html =~ ~s(phx-update="stream")
    assert html =~ "ROW-ONE"
    assert html =~ "NOTHING-HERE"
    assert html =~ ~s(id="things-empty")
    assert html =~ ~s(id="things-sentinel")
    assert html =~ ~s(phx-hook="InfiniteScroll")
  end

  test "omits the sentinel when has_more is false and shows the end label" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.infinite_scroll id="things" has_more={false} end_label="All caught up">
        <div id="things-1">ROW</div>
      </.infinite_scroll>
      """)

    refute html =~ ~s(id="things-sentinel")
    refute html =~ ~s(phx-hook="InfiniteScroll")
    assert html =~ "All caught up"
  end

  test "footer alone renders a sentinel for table lists" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.infinite_scroll_footer id="rows" has_more={true} />
      """)

    assert html =~ ~s(id="rows-sentinel")
    assert html =~ ~s(phx-hook="InfiniteScroll")
    assert html =~ "animate-spin"
  end
end
