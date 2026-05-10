defmodule Cympho.Adapters.AgrentingAdapter do
  @moduledoc """
  Remote marketplace adapter for Agrenting hired agents.
  """

  @behaviour Cympho.Adapters.Adapter

  alias Cympho.Agrenting.Client
  alias Cympho.Projects
  alias Cympho.WorkProducts

  @default_base_url "https://www.agrenting.com"
  @default_poll_interval 2_500
  @default_timeout 1_800_000
  @terminal_statuses ~w(completed failed cancelled disputed refunded)

  @impl true
  def run(issue, agent_id, recipient_pid, opts) when is_pid(recipient_pid) do
    session_id = make_ref()
    config = opts[:config] || %{}

    spawn(fn ->
      do_run(session_id, issue, agent_id, recipient_pid, config, opts)
    end)

    session_id
  end

  defp do_run(session_id, issue, agent_id, recipient_pid, config, opts) do
    send(recipient_pid, {:session_started, session_id})

    prompt =
      Cympho.AgentPrompt.build(issue, agent_id,
        skills: Keyword.get(opts, :skills, []),
        runtime_context: Keyword.get(opts, :runtime_context)
      )

    case dispatch_and_wait(issue, agent_id, prompt, config, opts) do
      {:ok, result} ->
        send(recipient_pid, {:turn_completed, session_id, result})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp dispatch_and_wait(issue, agent_id, prompt, config, opts) do
    with {:ok, agent_did} <- required_config(config, "agent_did"),
         {:ok, capability} <- required_config(config, "capability"),
         {:ok, max_price} <- required_config(config, "max_price"),
         {:ok, config} <- prepare_delivery_config(issue, config),
         {:ok, create_response} <-
           Client.create_hiring(
             config,
             agent_did,
             hiring_attrs(issue, agent_id, prompt, config, opts, capability, max_price)
           ),
         {:ok, hiring_id} <- hiring_id(create_response),
         {:ok, hiring} <- poll_hiring(config, hiring_id, timeout(config), poll_interval(config)) do
      case hiring["status"] do
        "completed" ->
          _ = attach_remote_artifacts(issue, agent_id, config, hiring)
          {:ok, format_completed_turn(hiring)}

        status when status in @terminal_statuses ->
          {:error, {:agrenting_hiring_terminal, status, failure_reason(hiring)}}

        status ->
          {:error, {:agrenting_hiring_not_terminal, status}}
      end
    end
  end

  defp prepare_delivery_config(issue, config) do
    case delivery_mode(config) do
      "push" ->
        config
        |> put_config_new("repo_url", repo_url_for_issue(issue))
        |> put_config_new("repo_access_token", repo_token(config))
        |> require_push_config()

      _ ->
        {:ok, Map.put(config, "delivery_mode", "output")}
    end
  end

  defp require_push_config(config) do
    cond do
      blank?(config_value(config, "repo_url")) ->
        {:error, :agrenting_push_repo_url_missing}

      blank?(config_value(config, "repo_access_token")) ->
        {:error, :agrenting_push_repo_token_missing}

      true ->
        {:ok, Map.put(config, "delivery_mode", "push")}
    end
  end

  defp hiring_attrs(issue, agent_id, prompt, config, opts, capability, max_price) do
    %{
      "task_description" => task_description(issue),
      "capability_requested" => capability,
      "price" => max_price,
      "delivery_mode" => delivery_mode(config),
      "task_input" => %{
        "source" => "cympho",
        "cympho_issue_id" => field(issue, :id),
        "cympho_issue_identifier" => field(issue, :identifier),
        "cympho_agent_id" => agent_id,
        "cympho_prompt" => prompt,
        "return_contract" =>
          "Return a Cympho-ready final comment. Include a valid cympho-actions JSON block."
      }
    }
    |> put_optional("repo_url", config_value(config, "repo_url"))
    |> put_optional("repo_access_token", config_value(config, "repo_access_token"))
    |> put_optional("client_idempotency_key", idempotency_key(issue, agent_id, opts))
  end

  defp task_description(issue) do
    title = field(issue, :title) || "Untitled Cympho issue"
    identifier = field(issue, :identifier) || field(issue, :id)
    description = field(issue, :description) || "No issue description provided."

    """
    Cympho issue #{identifier}: #{title}

    #{description}
    """
    |> String.trim()
    |> String.slice(0, 4_900)
  end

  defp idempotency_key(issue, agent_id, opts) do
    run_id =
      case Keyword.get(opts, :runtime_context) do
        %{run_id: run_id} when is_binary(run_id) -> run_id
        _ -> nil
      end

    if run_id do
      "cympho:#{field(issue, :id)}:#{agent_id}:#{run_id}"
      |> String.slice(0, 128)
    end
  end

  defp poll_hiring(config, hiring_id, timeout_ms, poll_interval_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_hiring(config, hiring_id, deadline, poll_interval_ms)
  end

  defp do_poll_hiring(config, hiring_id, deadline, poll_interval_ms) do
    with {:ok, hiring} <- Client.get_hiring(config, hiring_id) do
      status = hiring["status"]

      cond do
        status in @terminal_statuses ->
          {:ok, hiring}

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, {:agrenting_timeout, hiring_id, status}}

        true ->
          Process.sleep(poll_interval_ms)
          do_poll_hiring(config, hiring_id, deadline, poll_interval_ms)
      end
    end
  end

  defp format_completed_turn(hiring) do
    output = hiring["task_output"] || %{}
    body = output_text(output)
    artifacts = List.wrap(hiring["artifacts"])

    body =
      if body == "" do
        "Agrenting hiring #{hiring["id"]} completed."
      else
        body
      end

    footer =
      [
        "",
        "---",
        "Agrenting hiring: #{hiring["id"]}",
        "Remote agent: #{get_in(hiring, ["agent", "name"]) || get_in(hiring, ["agent", "did"]) || "unknown"}",
        artifact_summary(artifacts)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n")

    %{
      "content" => [%{"type" => "text", "text" => String.trim(body <> "\n" <> footer)}],
      "agrenting" => %{
        "hiring_id" => hiring["id"],
        "status" => hiring["status"],
        "artifacts" => artifacts
      }
    }
  end

  defp attach_remote_artifacts(issue, agent_id, config, hiring) do
    hiring
    |> Map.get("artifacts", [])
    |> List.wrap()
    |> Enum.each(fn artifact ->
      attrs = %{
        issue_id: field(issue, :id),
        created_by_agent_id: agent_id,
        kind: "artifact",
        title: artifact["name"] || "Agrenting artifact #{artifact["id"]}",
        description: "Produced by Agrenting hiring #{hiring["id"]}.",
        url: artifact_download_url(config, artifact["id"]),
        metadata: %{
          "source" => "agrenting",
          "hiring_id" => hiring["id"],
          "artifact_id" => artifact["id"],
          "artifact_type" => artifact["artifact_type"],
          "content_type" => artifact["content_type"],
          "language" => artifact["language"],
          "size_bytes" => artifact["size_bytes"]
        }
      }

      _ = WorkProducts.create_work_product(attrs)
    end)
  end

  defp artifact_download_url(_config, nil), do: nil

  defp artifact_download_url(config, artifact_id) do
    base =
      config_value(config, "base_url") ||
        config_value(config, "agrenting_url") ||
        Application.get_env(:cympho, :agrenting_url) ||
        @default_base_url

    String.trim_trailing(base, "/") <> "/api/v1/artifacts/#{URI.encode(artifact_id)}/download"
  end

  defp artifact_summary([]), do: nil

  defp artifact_summary(artifacts) do
    names =
      artifacts
      |> Enum.map(&(&1["name"] || &1["id"]))
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    "Remote artifacts: #{names}"
  end

  defp output_text(value) when is_binary(value), do: value

  defp output_text(%{"content" => content}) when is_binary(content), do: content

  defp output_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      text when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp output_text(output) when is_map(output) do
    Enum.find_value(["text", "output", "summary", "result", "message"], "", fn key ->
      value = Map.get(output, key)
      if is_binary(value) and value != "", do: value
    end)
    |> case do
      "" -> inspect(output)
      text -> text
    end
  end

  defp output_text(_), do: ""

  defp hiring_id(%{"hiring" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp hiring_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp hiring_id(_), do: {:error, :agrenting_hiring_id_missing}

  defp failure_reason(hiring) do
    hiring["failed_reason"] || hiring["status"] || "Agrenting hiring ended without output."
  end

  defp repo_url_for_issue(%{project: %{repo_url: repo_url}}) when is_binary(repo_url),
    do: repo_url

  defp repo_url_for_issue(%{project_id: project_id}) when is_binary(project_id) do
    case Projects.get_project(project_id) do
      {:ok, %{repo_url: repo_url}} -> repo_url
      _ -> nil
    end
  end

  defp repo_url_for_issue(_), do: nil

  defp repo_token(config) do
    config_value(config, "repo_access_token") ||
      get_in(config, ["env", "AGRENTING_REPO_ACCESS_TOKEN"]) ||
      get_in(config, ["env", "GITHUB_TOKEN"])
  end

  defp required_config(config, key) do
    case config_value(config, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_number(value) -> {:ok, to_string(value)}
      _ -> {:error, String.to_atom("agrenting_#{key}_missing")}
    end
  end

  defp config_value(config, key), do: Client.config_value(config, key)

  defp delivery_mode(config) do
    case config_value(config, "delivery_mode") do
      "push" -> "push"
      _ -> "output"
    end
  end

  defp timeout(config), do: int_config(config, "timeout", @default_timeout)
  defp poll_interval(config), do: int_config(config, "poll_interval_ms", @default_poll_interval)

  defp int_config(config, key, default) do
    case config_value(config, key) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} when int > 0 -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp put_optional(map, _key, value) when value in [nil, ""], do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp put_config_new(config, _key, value) when value in [nil, ""], do: config
  defp put_config_new(config, key, value), do: Map.put_new(config, key, value)

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_, _), do: nil

  defp blank?(value), do: value in [nil, ""]

  @impl true
  def health_check(config) do
    cond do
      blank?(config_value(config || %{}, "api_key")) ->
        %{
          status: :unhealthy,
          message: "AGRENTING_API_KEY is not configured for this agent/company.",
          checked_at: DateTime.utc_now()
        }

      true ->
        case Client.list_agents(config || %{}, %{"status" => "active"}) do
          {:ok, _agents} ->
            %{
              status: :healthy,
              message: "Agrenting marketplace API is reachable.",
              checked_at: DateTime.utc_now()
            }

          {:error, reason} ->
            %{
              status: :unhealthy,
              message: "Agrenting check failed: #{inspect(reason)}",
              checked_at: DateTime.utc_now()
            }
        end
    end
  end

  @impl true
  def config_schema do
    [
      %{
        key: :agent_did,
        type: :string,
        required: true,
        default: nil,
        description: "Agrenting agent DID"
      },
      %{
        key: :capability,
        type: :string,
        required: true,
        default: nil,
        description: "Default capability to hire"
      },
      %{
        key: :max_price,
        type: :string,
        required: true,
        default: nil,
        description: "Maximum price per Cympho issue run"
      },
      %{
        key: :delivery_mode,
        type: :string,
        required: false,
        default: "output",
        description: "output or push"
      },
      %{
        key: :base_url,
        type: :string,
        required: false,
        default: @default_base_url,
        description: "Agrenting base URL"
      },
      %{
        key: :api_key,
        type: :string,
        required: false,
        default: nil,
        description: "Agrenting API key, usually supplied by company secrets"
      },
      %{
        key: :timeout,
        type: :integer,
        required: false,
        default: @default_timeout,
        description: "Polling timeout in milliseconds"
      }
    ]
  end

  @impl true
  def name, do: "Agrenting"

  @impl true
  def type, do: :agrenting

  @impl true
  def available?, do: true

  @impl true
  def available?(_config), do: true

  @impl true
  def validate_config(_config), do: :ok
end
