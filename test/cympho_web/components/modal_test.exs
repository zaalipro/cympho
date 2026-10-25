defmodule CymphoWeb.CoreComponents.ModalTest do
  @moduledoc """
  `CymphoWeb.CoreComponents.modal/1` in Paper & Ink (v7 §3.1 B9): a labelled
  paper dialog over a scrim, hidden with the `hidden` class, a named close button.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import CymphoWeb.CoreComponents, only: [modal: 1]

  alias Phoenix.LiveView.JS

  defp doc(show) do
    assigns = %{show: show}

    ~H"""
    <.modal id="versions-modal" show={@show} on_cancel={JS.push("close_versions")} title="Versions">
      <p class="body-marker">body</p>
      <:footer><button type="button" class="pl">Close</button></:footer>
    </.modal>
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
  end

  defp attr_of(node, name), do: node |> Floki.attribute(name) |> List.first()
  defp classes(node), do: node |> attr_of("class") |> String.split()

  test "a shown modal is a labelled dialog over a scrim" do
    html = doc(true)

    assert [wrapper] = Floki.find(html, "#versions-modal")
    assert classes(wrapper) == ["dlg-w"]
    assert [scrim] = Floki.find(wrapper, ".dlg-s")
    assert attr_of(scrim, "phx-click") =~ "close_versions"
    assert [dialog] = Floki.find(wrapper, "section.dlg")
    assert attr_of(dialog, "role") == "dialog"
    assert attr_of(dialog, "aria-modal") == "true"
    assert attr_of(dialog, "aria-labelledby") == "versions-modal-t"
    assert Floki.text(Floki.find(dialog, "h2.h2#versions-modal-t")) == "Versions"
    assert Floki.find(dialog, ".body-marker") != []
    assert Floki.find(dialog, ".dlg-f button.pl") != []
  end

  test "the close button is named and cancels" do
    assert [close] = Floki.find(doc(true), "button.ib[aria-label='Close']")
    assert attr_of(close, "phx-click") =~ "close_versions"
    assert attr_of(close, "type") == "button"
  end

  test "a closed modal carries the hidden class" do
    assert [wrapper] = Floki.find(doc(false), "#versions-modal")
    assert classes(wrapper) == ["dlg-w", "hidden"]
  end
end
