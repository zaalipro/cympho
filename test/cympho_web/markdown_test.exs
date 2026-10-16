defmodule CymphoWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias CymphoWeb.Markdown

  defp render(text), do: text |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  test "nil and empty input render nothing" do
    assert Markdown.to_html(nil) == {:safe, ""}
    assert Markdown.to_html("") == {:safe, ""}
  end

  test "strips script vectors from raw HTML and links" do
    html =
      render("""
      <img src="x" onerror="alert(1)">

      [click](javascript:alert(2))

      <a href="javascript:alert(3)">x</a>

      <script>alert(4)</script>

      <svg onload="alert(5)"></svg>

      <iframe src="https://evil.example"></iframe>

      <a href="#" style="position:fixed" onclick="alert(6)">y</a>
      """)

    refute html =~ "onerror"
    refute html =~ "onload"
    refute html =~ "onclick"
    refute html =~ "javascript:"
    refute html =~ "<script"
    refute html =~ "<svg"
    refute html =~ "<iframe"
    refute html =~ "style="
  end

  test "strips class and style from tags the default sanitiser allows them on" do
    html =
      render("""
      <div style="position:fixed;inset:0;z-index:99999" class="fixed inset-0">
      <a href="https://phish.example">Session expired</a>
      </div>

      <span style="color:red" class="fixed">s</span>

      <pre class="fixed" style="position:fixed">p</pre>

      <code class="fixed" style="position:fixed">c</code>
      """)

    refute html =~ "style="
    refute html =~ "class="
    assert html =~ ~s(href="https://phish.example")
  end

  test "keeps ordinary markdown formatting" do
    html =
      render("""
      ## Heading

      Press <kbd>U</kbd> for **bold**, `code` and [a link](https://example.com).

      | a | b |
      |---|---|
      | 1 | 2 |

      ```elixir
      x = 1
      ```
      """)

    assert html =~ "<h2>Heading</h2>"
    assert html =~ "<kbd>U</kbd>"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<code>code</code>"
    assert html =~ ~s(href="https://example.com")
    assert html =~ "<table>"
    assert html =~ "<pre><code"
  end
end
