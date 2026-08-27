defmodule HomeWeb.LLMProxyController do
  use HomeWeb, :controller

  require Logger

  @project_headers ~w(
    x-home-project
    x-llm-project
    x-llm-project-id
    x-llm-project-name
    x-project
    x-project-id
    x-project-name
    x-project-slug
    x-litellm-project
  )
  @tool_headers ~w(
    x-home-tool
    x-llm-tool
    x-tool
    x-tool-id
    x-client-tool
  )
  @diagnostic_headers @project_headers ++
                        @tool_headers ++
                        ~w(x-home-client x-home-project-id x-home-directory x-home-directory-hash x-home-worktree x-home-session-id x-home-agent x-session-id x-parent-session-id user-agent)

  def models(conn, _params) do
    json(conn, Home.LLMProxy.models())
  end

  def chat_completions(conn, _params) do
    body = conn.body_params
    attribution = request_attribution(conn, body)
    project = attribution.project
    tool = attribution.tool

    log_proxy_request(conn, "chat.completions", body, attribution)

    if Home.LLMProxy.UsageTracker.project_allowed?(project) do
      if body["stream"] == true do
        stream_chat(conn, body, project, tool)
      else
        case Home.LLMProxy.chat_completion(body, project: project, tool: tool) do
          {:ok, response} -> json(conn, response)
          {:error, error} -> send_proxy_error(conn, error)
        end
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: %{message: "project disabled", type: "project_disabled"}})
    end
  end

  def embeddings(conn, _params) do
    body = conn.body_params
    attribution = request_attribution(conn, body)
    project = attribution.project
    tool = attribution.tool

    log_proxy_request(conn, "embeddings", body, attribution)

    if Home.LLMProxy.UsageTracker.project_allowed?(project) do
      case Home.LLMProxy.embeddings(body, project: project, tool: tool) do
        {:ok, response} -> json(conn, response)
        {:error, error} -> send_proxy_error(conn, error)
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: %{message: "project disabled", type: "project_disabled"}})
    end
  end

  defp stream_chat(conn, body, project, tool) do
    parent = self()

    task =
      Task.async(fn ->
        Home.LLMProxy.stream_chat_completion(
          body,
          fn event -> send(parent, {:llm_proxy_sse, event}) end,
          project: project,
          tool: tool
        )
      end)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    stream_loop(conn, task, System.monotonic_time(:millisecond) + 180_000)
  end

  defp stream_loop(conn, task, deadline_ms) do
    wait_ms = min(5_000, max(deadline_ms - System.monotonic_time(:millisecond), 0))

    receive do
      {:llm_proxy_sse, event} ->
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        stream_loop(conn, task, deadline_ms)

      {ref, {:ok, _response}} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        conn

      {ref, {:error, error}} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(proxy_error_body(error))}\n\n")
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        conn

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        Logger.error("LLM proxy stream crashed: #{inspect(reason)}")
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(proxy_error_body(reason))}\n\n")
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        conn
    after
      wait_ms ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          Task.shutdown(task, :brutal_kill)
          {:ok, conn} = chunk(conn, "data: #{Jason.encode!(proxy_error_body(:timeout))}\n\n")
          {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
          conn
        else
          {:ok, conn} = chunk(conn, ": proxy working\n\n")
          stream_loop(conn, task, deadline_ms)
        end
    end
  end

  defp send_proxy_error(conn, error) do
    status = error_status(error)

    conn
    |> put_status(status)
    |> json(proxy_error_body(error))
  end

  defp proxy_error_body(%{message: message, classification: classification}) do
    %{error: %{message: message, type: to_string(classification)}}
  end

  defp proxy_error_body(error) do
    %{error: %{message: inspect(error), type: "proxy_error"}}
  end

  defp error_status(%{status: status}) when is_integer(status), do: status
  defp error_status(%{classification: :auth}), do: 401
  defp error_status(%{classification: :rate_limit}), do: 429
  defp error_status(_), do: 502

  defp request_attribution(conn, body) do
    header_project =
      Enum.find_value(@project_headers, fn header ->
        case get_req_header(conn, header) do
          [value | _] when is_binary(value) ->
            present_string(value) && {:header, header, present_string(value)}

          _ ->
            nil
        end
      end)

    header_tool =
      Enum.find_value(@tool_headers, fn header ->
        case get_req_header(conn, header) do
          [value | _] when is_binary(value) ->
            present_string(value) && {:header, header, present_string(value)}

          _ ->
            nil
        end
      end)

    metadata_project = get_in(body, ["metadata", "project"])
    metadata_tool = get_in(body, ["metadata", "tool"])
    model_tool = tool_for_model(body["model"])

    {tool_source, tool_source_detail, tool} =
      cond do
        match?({:header, _, _}, header_tool) ->
          {:header, elem(header_tool, 1), elem(header_tool, 2)}

        present_string(metadata_tool) ->
          {:body, "metadata.tool", present_string(metadata_tool)}

        present_string(body["tool"]) ->
          {:body, "tool", present_string(body["tool"])}

        present_string(model_tool) ->
          {:model_alias, present_string(body["model"]), model_tool}

        true ->
          {nil, nil, nil}
      end

    {source, source_detail, project} =
      cond do
        match?({:header, _, _}, header_project) ->
          {:header, elem(header_project, 1), elem(header_project, 2)}

        present_string(metadata_project) ->
          {:body, "metadata.project", present_string(metadata_project)}

        present_string(body["project"]) ->
          {:body, "project", present_string(body["project"])}

        present_string(body["user"]) ->
          {:body, "user", present_string(body["user"])}

        present_string(tool) ->
          {:tool, "tool", "tools"}

        true ->
          {:fallback, "unattributed", "unattributed"}
      end

    %{
      project: project,
      tool: tool,
      source: source,
      source_detail: source_detail,
      tool_source: tool_source,
      tool_source_detail: tool_source_detail,
      headers: diagnostic_headers(conn)
    }
  end

  defp present_string(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  defp tool_for_model(model) do
    model = present_string(model)

    if model do
      Application.get_env(:home, :llm_tool_model_attribution, %{})
      |> Map.get(model)
      |> present_string()
    end
  end

  defp diagnostic_headers(conn) do
    @diagnostic_headers
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn header, acc ->
      case get_req_header(conn, header) do
        [value | _] -> Map.put(acc, header, diagnostic_header_value(header, value))
        _ -> acc
      end
    end)
  end

  defp diagnostic_header_value(header, value)
       when header in ~w(x-home-directory x-home-worktree) do
    value = present_string(value)

    if value do
      %{basename: Path.basename(value), hash: short_hash(value)}
    end
  end

  defp diagnostic_header_value(header, value)
       when header in ~w(x-home-project-id x-home-session-id x-session-id x-parent-session-id) do
    value = present_string(value)

    if value do
      %{hash: short_hash(value)}
    end
  end

  defp diagnostic_header_value(_header, value), do: present_string(value)

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp log_proxy_request(conn, operation, body, attribution) do
    payload = %{
      event: "llm_proxy_request",
      operation: operation,
      method: conn.method,
      path: conn.request_path,
      request_id: conn.assigns[:plug_request_id],
      model: body["model"],
      stream: body["stream"] == true,
      project: attribution.project,
      tool: attribution.tool,
      attribution_source: attribution.source,
      attribution_source_detail: attribution.source_detail,
      tool_attribution_source: attribution.tool_source,
      tool_attribution_source_detail: attribution.tool_source_detail,
      diagnostic_headers: attribution.headers
    }

    level = if attribution.source == :fallback, do: :warning, else: :info
    Logger.log(level, fn -> Jason.encode!(payload) end)
  end
end
