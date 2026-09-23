defmodule Cympho.ApplicationFinchTest do
  use ExUnit.Case, async: true

  test "running Finch uses the configured default pool size" do
    assert Process.whereis(Cympho.Finch)
    assert {:ok, config} = Registry.meta(Cympho.Finch, :config)

    expected_size =
      :cympho
      |> Application.fetch_env!(Cympho.Finch)
      |> Keyword.fetch!(:pools)
      |> Keyword.fetch!(:default)
      |> Keyword.fetch!(:size)

    assert config.default_pool_config.size == expected_size

    if Application.fetch_env!(:cympho, :resource_profile) == "low" and
         System.get_env("CYMPHO_FINCH_POOL_SIZE") in [nil, ""] do
      assert config.default_pool_config.size == 2
    end
  end
end
