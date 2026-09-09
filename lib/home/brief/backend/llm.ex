defmodule Home.Brief.Backend.LLM do
  @moduledoc """
  The default brief backend: a single text completion through the local LLM
  proxy (`Home.LLMProxy`). Cheap and fast; no tool use.
  """

  alias Home.Brief.Conversation
  alias Home.Brief.Prompt
  alias Home.Brief.Runner
  alias Home.LLMProxy

  def available?(_backend), do: true

  def run(%Prompt{} = prompt, %Conversation{} = brief) do
    messages = Runner.build_messages(prompt, brief)

    with {:ok, response} <- call_llm(messages, prompt.model),
         {:ok, parsed} <- Runner.parse_response(response.content) do
      {:ok,
       %{
         content: response.content,
         parsed: parsed,
         model_used: response.model,
         cost_usd: response.cost,
         metadata: %{}
       }}
    end
  end

  defp call_llm(messages, model_override) do
    model = model_override || "coder"

    body = %{
      "model" => model,
      "messages" => messages,
      "temperature" => 0.4,
      "max_tokens" => 4096
    }

    case LLMProxy.chat_completion(body, project: "briefs", tool: "brief") do
      {:ok, response} ->
        with %{choices: [%{message: %{content: content}} | _]} <- response,
             current_model <- Map.get(response, :model, model),
             usage <- Map.get(response, :usage, %{}),
             cost <- estimate_cost(current_model, usage) do
          {:ok, %{content: content, model: current_model, cost: cost}}
        else
          _ -> {:error, {:malformed_response, response}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp estimate_cost(model, usage) do
    input = usage["prompt_tokens"] || usage[:prompt_tokens] || 0
    output = usage["completion_tokens"] || usage[:completion_tokens] || 0
    Home.LLMProxy.UsageTracker.cost_for(model, input, output)
  end
end
