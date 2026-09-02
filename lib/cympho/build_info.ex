defmodule Cympho.BuildInfo.Validation do
  @moduledoc false

  @revision_pattern ~r/\A[0-9a-fA-F]{7,64}\z/

  @doc false
  def revision(value, environment) do
    if is_binary(value) and Regex.match?(@revision_pattern, value) do
      String.downcase(value)
    else
      fallback(environment)
    end
  end

  @doc false
  def identity_valid?(value, environment) do
    (is_binary(value) and Regex.match?(@revision_pattern, value)) or
      (environment in [:dev, :test] and value == "development")
  end

  defp fallback(environment) when environment in [:dev, :test], do: "development"
  defp fallback(_environment), do: "unknown"
end

defmodule Cympho.BuildInfo do
  @moduledoc """
  Immutable identity embedded when Cympho is compiled.

  Release builds should set `CYMPHO_BUILD_REVISION` to the Git object ID used
  for the build. Invalid or absent values never flow into public responses.
  """

  alias Cympho.BuildInfo.Validation

  @version Mix.Project.config() |> Keyword.fetch!(:version) |> to_string()
  @environment Mix.env()
  @revision Validation.revision(System.get_env("CYMPHO_BUILD_REVISION"), @environment)

  @spec version() :: String.t()
  def version, do: @version

  @spec revision() :: String.t()
  def revision, do: @revision

  @spec identity_valid?() :: boolean()
  def identity_valid?, do: Validation.identity_valid?(@revision, @environment)

  @spec release() :: %{version: String.t(), revision: String.t()}
  def release, do: %{version: @version, revision: @revision}
end
