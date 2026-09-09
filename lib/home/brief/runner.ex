defmodule Home.Brief.Runner do
  @moduledoc """
  Executes one brief end-to-end and persists the result.

  Delegates execution to the backend configured on the prompt (see
  `Home.Brief.Backend`): the local LLM proxy (`llm`, default), the remote
  agent-forge daemon (`agent_forge`), or a local agentic CLI backend
  (`opencode` / `claude_code` / `codex`). Each backend returns a flat result
  map; this module handles the common persistence, message recording, and
  failure bookkeeping.

  Pure-toward-failure: any error is recorded on the brief as a human-readable
  `error` with status `failed` — the scheduler never auto-retries.
  """

  alias Home.Brief
  alias Home.Brief.{Backend, Conversation, Prompt}

  @doc """
  Run a brief end-to-end. Returns `{:ok, brief}` on completion or
  `{:error, {brief, reason}}` when the execution failed (failure is recorded
  on the brief with status `failed`).
  """
  @spec run(Prompt.t(), Conversation.t()) :: {:ok, Conversation.t()} | {:error, term()}
  def run(%Prompt{} = prompt, %Conversation{} = brief) do
    result =
      case Backend.run(prompt, brief) do
        {:ok, result} -> persist_success(prompt, brief, result)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, updated} ->
        {:ok, updated}

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

  @doc "True when the backend dispatch is active for a prompt."
  def dispatch?(%Prompt{} = prompt) do
    prompt.backend != "llm"
  end

  @doc "Backend identifiers a prompt may use."
  def backends, do: Prompt.backends()

  # ── Persistence ──────────────────────────────────────────────────────────

  # A backend returns `{:ok, result}` where result is:
  #   %{content: string, summary: string, next_steps: [string],
  #     model_used: string, cost_usd: number, metadata: map}
  defp persist_success(prompt, brief, result) do
    parsed =
      case result.parsed do
        %{summary: _, next_steps: _} = parsed ->
          parsed

        _ ->
          case parse_response(result.content) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{summary: self_summary(result.content), next_steps: []}
          end
      end

    attrs = %{
      status: "completed",
      outcome: result.content,
      summary: parsed.summary,
      next_steps: parsed.next_steps,
      completed_at: DateTime.utc_now(),
      model_used: result.model_used,
      cost_usd: result.cost_usd,
      metadata: Map.merge(prompt.metadata || %{}, result.metadata || %{})
    }

    case Brief.update_brief(brief, attrs) do
      {:ok, updated} ->
        Brief.add_message(brief, "assistant", result.content)
        remember_brief(updated, prompt)
        {:ok, updated}

      {:error, _} = error ->
        error
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

  defp self_summary(content) when is_binary(content), do: first_line(content)
  defp self_summary(_), do: ""

  defp first_line(text), do: text |> String.split("\n") |> List.first() |> String.trim()

  defp extract_next_steps(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- [ ]"))
    |> Enum.map(&(String.replace_prefix(&1, "- [ ]", "") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
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
