defmodule CymphoWeb.Plugs.ContentSecurityPolicyTest do
  use CymphoWeb.ConnCase, async: true

  test "browser pages carry a nonce-based script policy that matches inline scripts", %{
    conn: conn
  } do
    conn = get(conn, "/docs")
    html = html_response(conn, 200)

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "object-src 'none'"
    assert policy =~ "base-uri 'self'"
    refute policy =~ "script-src 'self' 'unsafe-inline'"

    [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, policy)

    inline_scripts = Regex.scan(~r/<script(?![^>]*\bsrc=)([^>]*)>/, html)
    assert inline_scripts != []

    for [_tag, attrs] <- inline_scripts do
      assert attrs =~ ~s(nonce="#{nonce}"), "inline script without the request nonce: #{attrs}"
    end

    external_scripts = Regex.scan(~r/<script[^>]*\bsrc="(https:[^"]+)"/, html)
    assert external_scripts != []

    for [_, src] <- external_scripts do
      assert policy =~ src, "external script not allowed by script-src: #{src}"
    end

    refute policy =~ ~r/script-src[^;]*https:\/\/cdn\.jsdelivr\.net[ ;]/
  end

  test "each request gets a fresh nonce", %{conn: conn} do
    [first] = conn |> get("/docs") |> get_resp_header("content-security-policy")
    [second] = build_conn() |> get("/docs") |> get_resp_header("content-security-policy")

    refute first == second
  end
end
