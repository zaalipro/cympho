defmodule Cympho.Routing.LlmClassifier do
  @moduledoc """
  Classifies an issue's role via a single Anthropic Messages API call.

  Returns `{:ok, role}` where `role` is one of
  `:ceo | :cto | :product_manager | :designer | :engineer | :release_engineer`,
  or `{:error, reason}` otherwise. Reasons include
  `:missing_api_key`, `:disabled`, `:timeout`, `{:http_error, status}`,
  `:invalid_response`, or any underlying Finch error.

  The classifier only sends the issue's title, description, project name,
  and company name. No comments, no secrets, no other agent context.
  """

  require Logger

  @endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @model "claude-haiku-4-5-20251001"
  @default_timeout_ms 1_500

  @roles ~w[ceo cto product_manager designer engineer release_engineer]

  @doc """
  Classifies an issue. Options:

    * `:timeout_ms` — overrides the configured timeout
    * `:finch_name` — overrides the Finch pool (test-only injection)
    * `:api_key` — overrides the env/config key (test-only)
  """
  @spec classify(map(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def classify(issue, opts \\ []) when is_map(issue) do
    cond do
      not enabled?() ->
        {:error, :disabled}

      api_key(opts) in [nil, ""] ->
        {:error, :missing_api_key}

      true ->
        do_classify(issue, opts)
    end
  end

  defp do_classify(issue, opts) do
    timeout =
      opts[:timeout_ms] ||
        Application.get_env(:cympho, :llm_classifier_timeout_ms, @default_timeout_ms)

    prompt = build_prompt(issue)

    body =
      Jason.encode!(%{
        model: @model,
        max_tokens: 64,
        messages: [%{role: "user", content: prompt}]
      })

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key(opts)},
      {"anthropic-version", @anthropic_version}
    ]

    finch = opts[:finch_name] || Application.get_env(:cympho, :finch_name, Cympho.Finch)

    request = Finch.build(:post, @endpoint, headers, body)

    case Finch.request(request, finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        parse_response(response_body)

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(body) do
    with {:ok, decoded} <- Jason.decode(body),
         %{"content" => content} when is_list(content) <- decoded,
         text when is_binary(text) <- extract_text(content),
         {:ok, role} <- extract_role(text) do
      {:ok, role}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp extract_text(content) do
    Enum.find_value(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp extract_role(text) do
    # Accept either a bare role token or a JSON object {"role": "..."}.
    cleaned = text |> String.trim() |> String.downcase()

    role_from_json =
      with {:ok, %{"role" => role}} <- Jason.decode(cleaned),
           true <- is_binary(role) do
        role
      else
        _ -> nil
      end

    role_string = role_from_json || cleaned

    if role_string in @roles do
      {:ok, String.to_existing_atom(role_string)}
    else
      :error
    end
  end

  defp build_prompt(issue) do
    title = field(issue, :title) || ""
    description = field(issue, :description) || ""
    project = project_name(issue)
    company = company_name(issue)

    """
    You classify engineering issues into one of these roles:
    - ceo (strategic/business/funding/vision)
    - cto (architecture/technical-direction/platform-decisions)
    - product_manager (roadmap/requirements/prioritisation)
    - designer (ux/ui/interface/workflow)
    - engineer (implementation/bug-fixes/features/tests)
    - release_engineer (merges/deploys/release-coordination/conflicts)

    Respond with exactly one role token from the list above. No prose.

    Company: #{company}
    Project: #{project}

    Title: #{title}
    Description: #{description}
    """
  end

  defp project_name(issue) do
    case field(issue, :project) do
      %{name: name} when is_binary(name) -> name
      _ -> "(none)"
    end
  end

  defp company_name(issue) do
    case field(issue, :company) do
      %{name: name} when is_binary(name) -> name
      _ -> "(unknown)"
    end
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_, _), do: nil

  defp enabled? do
    Application.get_env(:cympho, :llm_router_enabled?, true) == true
  end

  defp api_key(opts) do
    opts[:api_key] ||
      Application.get_env(:cympho, :anthropic_api_key) ||
      System.get_env("ANTHROPIC_API_KEY")
  end

  @doc """
  Reports whether the classifier is configured and enabled. Used by the
  Routing context to decide whether to attempt a network call.
  """
  @spec configured?() :: boolean()
  def configured? do
    enabled?() and api_key([]) not in [nil, ""]
  end

  @doc false
  def model, do: @model
end
