defmodule Home.LLMProxy do
  @moduledoc """
  OpenAI-compatible local proxy that replaces the local LiteLLM process.
  """

  alias Agentic.LLM.Response
  alias Home.LLMProxy.{ModelRouting, UsageTracker}

  @no_failover [:context_overflow]

  def models do
    %{
      object: "list",
      data:
        [
          %{id: "coder", object: "model", owned_by: "home"},
          %{id: "planner", object: "model", owned_by: "home"},
          %{id: "memory", object: "model", owned_by: "home"}
        ] ++ ModelRouting.public_models() ++ Home.LLMProxy.ProviderCatalog.models()
    }
  end

  def chat_completion(body, opts \\ []) when is_map(body) do
    requested_model = Map.get(body, "model", "coder")
    context = usage_context(opts)

    requested_model
    |> ModelRouting.resolve_chain(:chat)
    |> UsageTracker.apply_project_policy(context.project, :chat)
    |> try_chat_routes(
      canonical_chat_params(body),
      nil,
      public_model_name(requested_model),
      context
    )
  end

  def stream_chat_completion(body, on_event, opts \\ [])
      when is_map(body) and is_function(on_event, 1) do
    requested_model = Map.get(body, "model", "coder")
    context = usage_context(opts)

    route_chain =
      requested_model
      |> ModelRouting.resolve_chain(:chat)
      |> UsageTracker.apply_project_policy(context.project, :chat)

    params = canonical_chat_params(body)

    case try_stream_routes(
           route_chain,
           params,
           on_event,
           nil,
           public_model_name(requested_model),
           context
         ) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  def embeddings(body, opts \\ []) when is_map(body) do
    input = Map.get(body, "input")
    context = usage_context(opts)

    body
    |> Map.get("model", "memory")
    |> ModelRouting.resolve_chain(:embedding)
    |> UsageTracker.apply_project_policy(context.project, :embedding)
    |> try_embedding_routes(input, nil, context)
  end

  defp try_chat_routes([], _params, last_error, _public_model, _context),
    do: {:error, last_error || :no_model_available}

  defp try_chat_routes([route | rest], params, _last_error, public_model, context) do
    case safe_call(fn -> client().chat(route, params) end) do
      {:ok, %Response{} = response} ->
        report_success(route, response, context)
        {:ok, openai_chat_response(response, public_model)}

      {:error, error} ->
        report_error(route, error)

        if failover_worthy?(error) do
          try_chat_routes(rest, params, error, public_model, context)
        else
          {:error, error}
        end
    end
  end

  defp try_stream_routes(routes, params, on_event, last_error, public_model, context) do
    id = completion_id()
    created = System.system_time(:second)
    emit_stream_role(on_event, id, created, public_model)

    try_stream_routes(routes, params, on_event, last_error, public_model, id, created, context)
  end

  defp try_stream_routes(
         [],
         _params,
         _on_event,
         last_error,
         _public_model,
         _id,
         _created,
         _context
       ),
       do: {:error, last_error || :no_model_available}

  defp try_stream_routes(
         [route | rest],
         params,
         on_event,
         _last_error,
         public_model,
         id,
         created,
         context
       ) do
    result =
      safe_call(fn ->
        client().stream_chat(route, params, fn text ->
          on_event.(stream_text_chunk(id, created, public_model, text))
        end)
      end)

    case result do
      {:ok, %Response{} = response} ->
        report_success(route, response, context)
        emit_stream_done(on_event, id, created, public_model, response.stop_reason)
        {:ok, response}

      {:error, error} ->
        report_error(route, error)

        if failover_worthy?(error) and rest != [] do
          on_event.(stream_text_chunk(id, created, public_model, failover_message(error)))
          try_stream_routes(rest, params, on_event, error, public_model, id, created, context)
        else
          {:error, error}
        end
    end
  end

  defp try_embedding_routes([], _input, last_error, _context),
    do: {:error, last_error || :no_model_available}

  defp try_embedding_routes([route | rest], input, _last_error, context) do
    case safe_call(fn -> client().embeddings(route, input) end) do
      {:ok, vectors} ->
        Home.LLMProxy.ProviderHealth.report_success(route, 0)
        record_embedding(route, context)
        {:ok, openai_embedding_response(vectors, route)}

      {:error, error} ->
        report_error(route, error)

        if failover_worthy?(error) do
          try_embedding_routes(rest, input, error, context)
        else
          {:error, error}
        end
    end
  end

  defp canonical_chat_params(body) do
    %{
      "messages" => canonical_messages(Map.get(body, "messages", [])),
      "tools" => canonical_tools(Map.get(body, "tools", [])),
      "max_tokens" => body["max_tokens"] || body["max_completion_tokens"],
      "temperature" => body["temperature"],
      "tool_choice" => canonical_tool_choice(body["tool_choice"])
    }
    |> reject_nil_values()
  end

  defp canonical_messages(messages) when is_list(messages) do
    Enum.flat_map(messages, fn
      %{"role" => "assistant", "tool_calls" => calls} = message when is_list(calls) ->
        content =
          List.wrap(text_block(message["content"])) ++ Enum.map(calls, &tool_call_block/1)

        [%{"role" => "assistant", "content" => Enum.reject(content, &is_nil/1)}]

      %{"role" => "tool", "tool_call_id" => id, "content" => content} ->
        [
          %{
            "role" => "user",
            "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => content}]
          }
        ]

      %{"role" => role, "content" => content} ->
        [%{"role" => role, "content" => content}]

      other when is_map(other) ->
        [other]

      _ ->
        []
    end)
  end

  defp canonical_messages(_), do: []

  defp text_block(text) when is_binary(text) and text != "",
    do: %{"type" => "text", "text" => text}

  defp text_block(_), do: nil

  defp tool_call_block(%{"id" => id, "function" => %{"name" => name} = function}) do
    %{
      "type" => "tool_use",
      "id" => id,
      "name" => name,
      "input" => decode_arguments(function["arguments"])
    }
  end

  defp tool_call_block(_), do: nil

  defp canonical_tools(tools) when is_list(tools) do
    Enum.map(tools, fn
      %{"type" => "function", "function" => function} ->
        %{
          "name" => function["name"],
          "description" => function["description"] || "",
          "input_schema" => function["parameters"] || %{"type" => "object"}
        }

      %{"name" => _} = tool ->
        tool

      tool ->
        tool
    end)
  end

  defp canonical_tools(_), do: []

  defp canonical_tool_choice("required"), do: :required
  defp canonical_tool_choice("auto"), do: :auto
  defp canonical_tool_choice("none"), do: :none
  defp canonical_tool_choice(other), do: other

  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_arguments(args) when is_map(args), do: args
  defp decode_arguments(_), do: %{}

  defp openai_chat_response(%Response{} = response, public_model) do
    {content, tool_calls} = response_content(response)

    message =
      %{
        role: "assistant",
        content: content
      }
      |> maybe_put(:tool_calls, if(tool_calls == [], do: nil, else: tool_calls))

    %{
      id: completion_id(),
      object: "chat.completion",
      created: System.system_time(:second),
      model: public_model,
      choices: [
        %{
          index: 0,
          message: message,
          finish_reason: finish_reason(response.stop_reason)
        }
      ],
      usage: openai_usage(response.usage)
    }
  end

  defp response_content(%Response{content: content}) do
    Enum.reduce(content || [], {"", []}, fn
      %{type: :text, text: text}, {_content, calls} ->
        {text, calls}

      %{type: :tool_use, id: id, name: name, input: input}, {text, calls} ->
        call = %{
          id: id,
          type: "function",
          function: %{name: name, arguments: Jason.encode!(input || %{})}
        }

        {text, calls ++ [call]}

      _block, acc ->
        acc
    end)
  end

  defp openai_embedding_response(vectors, route) do
    %{
      object: "list",
      model: model_name(route),
      data:
        vectors
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.map(fn {embedding, index} ->
          %{object: "embedding", index: index, embedding: embedding}
        end),
      usage: %{prompt_tokens: 0, total_tokens: 0}
    }
  end

  defp emit_stream_role(on_event, id, created, model) do
    on_event.(%{
      id: id,
      object: "chat.completion.chunk",
      created: created,
      model: model,
      choices: [%{index: 0, delta: %{role: "assistant"}, finish_reason: nil}]
    })
  end

  defp stream_text_chunk(id, created, model, text) do
    %{
      id: id,
      object: "chat.completion.chunk",
      created: created,
      model: model,
      choices: [%{index: 0, delta: %{content: text}, finish_reason: nil}]
    }
  end

  defp emit_stream_done(on_event, id, created, model, stop_reason) do
    on_event.(%{
      id: id,
      object: "chat.completion.chunk",
      created: created,
      model: model,
      choices: [%{index: 0, delta: %{}, finish_reason: finish_reason(stop_reason)}]
    })
  end

  defp openai_usage(usage) when is_map(usage) do
    input = usage[:input_tokens] || usage["input_tokens"] || 0
    output = usage[:output_tokens] || usage["output_tokens"] || 0

    %{
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens: input + output
    }
  end

  defp openai_usage(_), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp finish_reason(:tool_use), do: "tool_calls"
  defp finish_reason(:max_tokens), do: "length"
  defp finish_reason(_), do: "stop"

  defp report_success({provider, model}, %Response{} = response, context) do
    usage = openai_usage(response.usage)
    latency_ms = elapsed_ms(context.started_at)
    Home.LLMProxy.ProviderHealth.report_success({provider, model}, usage.total_tokens, latency_ms)

    UsageTracker.record(%{
      project: context.project,
      tool: context.tool,
      provider: provider,
      model: response.model_id || model,
      input_tokens: usage.prompt_tokens,
      output_tokens: usage.completion_tokens,
      cost_usd: response.cost,
      latency_ms: latency_ms
    })
  end

  defp record_embedding({provider, model}, context) do
    UsageTracker.record(%{
      project: context.project,
      tool: context.tool,
      provider: provider,
      model: model,
      input_tokens: 0,
      output_tokens: 0,
      latency_ms: elapsed_ms(context.started_at)
    })
  end

  defp usage_context(opts) do
    %{
      project: Keyword.get(opts, :project, "unattributed"),
      tool: Keyword.get(opts, :tool),
      started_at: System.monotonic_time()
    }
  end

  defp elapsed_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp report_error(route, error) do
    Home.LLMProxy.ProviderHealth.report_error(
      route,
      Map.get(error, :classification, :error),
      Map.get(error, :retry_after_ms)
    )
  end

  defp failover_worthy?(%{classification: classification}), do: classification not in @no_failover
  defp failover_worthy?(_), do: true

  defp safe_call(fun) when is_function(fun, 0) do
    fun.()
  rescue
    e ->
      {:error, %{message: Exception.message(e), classification: :error, raw: e}}
  catch
    :exit, reason ->
      {:error, %{message: inspect(reason), classification: :error, raw: reason}}
  end

  defp client do
    :home
    |> Application.get_env(:llm_proxy, [])
    |> Keyword.get(:provider_client, Home.LLMProxy.ProviderClient)
  end

  defp model_name({provider, model}), do: "#{provider}/#{model}"

  defp public_model_name(model) when is_binary(model) and model != "", do: model
  defp public_model_name(_), do: "coder"

  defp failover_message(%{classification: classification}) do
    "\n\n[provider #{classification}; switching to backup model]\n\n"
  end

  defp failover_message(_error), do: "\n\n[provider failed; switching to backup model]\n\n"

  defp completion_id do
    "chatcmpl-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
