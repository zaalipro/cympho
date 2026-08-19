defmodule Cympho.ConfigurationSecurityTest do
  use ExUnit.Case, async: true

  test "production compiles secure cookies and the pre-socket SSL guard" do
    {config, _imports} = Config.Reader.read_imports!("config/config.exs", env: :prod)
    cympho = Keyword.fetch!(config, :cympho)

    session_options = Keyword.fetch!(cympho, :session_options)
    assert session_options[:secure]
    assert session_options[:http_only]
    assert session_options[:same_site] == "Lax"
    assert session_options[:max_age] == 604_800

    endpoint = Keyword.fetch!(cympho, CymphoWeb.Endpoint)
    force_ssl = Keyword.fetch!(endpoint, :force_ssl)

    assert force_ssl[:host] ==
             {CymphoWeb.Plugs.TransportSecurity, :configured_host, []}

    assert force_ssl[:exclude] == [
             conn: {CymphoWeb.Plugs.TransportSecurity, :exclude_from_builtin_ssl?, []}
           ]
  end
end
