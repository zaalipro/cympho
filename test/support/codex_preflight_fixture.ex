defmodule Cympho.CodexPreflightFixture do
  @moduledoc false

  def setup! do
    dir = Path.join(System.tmp_dir!(), "cympho-codex-preflight-#{Ecto.UUID.generate()}")
    File.mkdir!(dir)
    original_path = System.get_env("PATH")
    original_key = System.get_env("OPENAI_API_KEY")

    original_config =
      Map.new([:codex_bwrap_path, :openai_api_key], &{&1, Application.fetch_env(:cympho, &1)})

    ExUnit.Callbacks.on_exit(fn ->
      restore_env("PATH", original_path)
      restore_env("OPENAI_API_KEY", original_key)

      for {key, value} <- original_config do
        case value do
          {:ok, value} -> Application.put_env(:cympho, key, value)
          :error -> Application.delete_env(:cympho, key)
        end
      end

      File.rm_rf!(dir)
    end)

    File.chmod!(dir, 0o700)
    marker = Path.join(dir, "invoked")
    quoted_marker = "'" <> String.replace(marker, "'", "'\\''") <> "'"

    for command <- ["codex", "bwrap"] do
      path = Path.join(dir, command)
      File.write!(path, "#!/bin/sh\nprintf invoked > #{quoted_marker}\nexit 99\n")
      File.chmod!(path, 0o700)
    end

    System.put_env("PATH", "#{dir}:/usr/bin:/bin")
    System.delete_env("OPENAI_API_KEY")
    Application.delete_env(:cympho, :openai_api_key)
    Application.put_env(:cympho, :codex_bwrap_path, Path.join(dir, "bwrap"))

    %{codex_path: Path.join(dir, "codex"), cli_invocation_marker: marker}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
