defmodule Home.Brief.Runner do
  @moduledoc """
  Executes one brief: builds the prompt messages, calls the local LLM proxy,
  parses the structured markdown response, and persists the result.

  Pure-toward-failure: any error is recorded on the brief as a human-readable
  `error` with status `failed` — the scheduler never auto-retries.
  """

  alias Home.Brief
  alias Home.Brief.{Conversation, Prompt}
  alias Home.LLMProxy

  @doc """
  Run a brief end-to-end. Returns `{:ok, brief}` on completion or
  `{:error, {brief, reason}}` when the execution failed (failure is recorded
  on the brief with status `failed`).
  """
  @spec run(Prompt.t(), Conversation.t()) :: {:ok, Conversation.t()} | {:error, term()}
  def run(%Prompt{} = prompt, %Conversation{} = brief) do
    messages = build_messages(prompt, brief)

    with {:ok, response} <- call_llm(messages, prompt.model),
         {:ok, parsed} <- parse_response(response.content) do
      result =
        Brief.update_brief(brief, %{
          status: "completed",
          outcome: response.content,
          summary: parsed.summary,
          next_steps: parsed.next_steps,
          completed_at: DateTime.utc_now(),
          model_used: response.model,
          cost_usd: response.cost
        })

      case result do
        {:ok, updated} ->
          Brief.add_message(brief, "assistant", response.content)
          remember_brief(updated, prompt)
          {:ok, updated}

        {:error, _} = error ->
          error
      end
    else
      {:error, reason} ->
        now = DateTime.utc_now()
        error_message = human_error(reason)

        {:ok, failed} =
          Brief.update_brief(brief, %{
            status: "failed",
            error: error_message,
            completed_at: now
          })

        {:error, {failed, error_message}}
    end
  end

  @doc "Build the LLM messages for a prompt, resolving template variables."
  def build_messages(%Prompt{} = prompt, %Conversation{} = _brief) do
    now = DateTime.utc_now()
    date = DateTime.to_date(now)

    user_prompt =
      prompt.user_prompt
      |> String.replace("{{date}}", Date.to_string(date))
      |> String.replace("{{yesterday}}", Date.to_string(Date.add(date, -1)))
      |> String.replace("{{weekday}}", Calendar.strftime(date, "%A"))
      |> String.replace("{{last_run}}", Brief.last_completed_at(prompt.id))

    [
      %{"role" => "system", "content" => prompt.system_prompt},
      %{"role" => "user", "content" => user_prompt}
    ]
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

  @doc "Extract summary and next steps from a structured markdown outcome."
  def parse_response(content) when is_binary(content) do
    summary = extract_summary(content)
    next_steps = extract_next_steps(content)

    if summary == "" and next_steps == [] do
      {:error, :no_structured_content}
    else
      {:ok, %{summary: summary, next_steps: next_steps}}
    end
  end

  def parse_response(_), do: {:error, :no_structured_content}

  defp extract_summary(content) do
    # First paragraph after any leading `## Summary` heading; fall back to
    # the first non-empty line.
    case Regex.run(~r/(?m)^## Summary[^\n]*\n([^\n]*(?:\n(?!##).*)*)/, content) do
      [_, block] ->
        block
        |> String.trim()
        |> String.split(~r/(?m)(?:\r?\n){2,}/)
        |> List.first()
        |> case do
          nil -> content |> String.trim() |> first_line()
          text -> String.trim(text)
        end

      nil ->
        content |> String.trim() |> first_line()
    end
  end

  defp first_line(text), do: text |> String.split("\n") |> List.first() |> String.trim()

  defp extract_next_steps(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- [ ]"))
    |> Enum.map(&(String.replace_prefix(&1, "- [ ]", "") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp estimate_cost(model, usage) do
    input = usage["prompt_tokens"] || usage[:prompt_tokens] || 0
    output = usage["completion_tokens"] || usage[:completion_tokens] || 0
    Home.LLMProxy.UsageTracker.cost_for(model, input, output)
  end

  # Phase-3 write-through: the finished brief becomes a searchable memory
  # (`scope: "briefs"`, `source_id: "brief:BRF-XXXX"`). Best effort — a
  # failing memory write never fails the brief.
  defp remember_brief(%Brief.Conversation{number: number} = brief, prompt) do
    source_id = "brief:#{number}"

    if not Home.Memory.source_exists?("briefs", source_id) do
      tags =
        [prompt.category, "brief"]
        |> Enum.reject(&is_nil/1)

      content = "#{brief.summary || first_line(brief.outcome || "")}\n\n#{brief.outcome}"

      try do
        Home.Memory.remember(content,
          scope: "briefs",
          source_id: source_id,
          source: "brief",
          tags: tags
        )
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp human_error(reason) when is_binary(reason), do: reason

  defp human_error(%{message: message}) when is_binary(message), do: message

  defp human_error(%{classification: classification}) when not is_nil(classification),
    do: "provider #{classification}"

  defp human_error(reason), do: inspect(reason)
end
