defmodule Home.Brief.Backend.Agentic do
  @moduledoc """
  Local agentic CLI backend: runs a brief through the CLI agents —
  `:opencode`, `:claude_code`, `:codex`. Each binary must be on PATH.

  The CLI is executed directly (one invocation per brief); its final
  report on stdout is the outcome text — the CLI harness runs its own
  tool loop internally. Unlike the `llm` and `agent_forge` backends, the
  response is not required to carry a `## Summary` / checklist structure —
  if it has none, the first line is used as the summary.

  Execution is injected through `run_callback/0` (default: run the CLI
  subprocess directly) so tests can substitute a fake without a real CLI.
  """

  alias Home.Brief.{Conversation, Prompt}

  @profiles %{
    "opencode" => :opencode,
    "claude_code" => :claude_code,
    "codex" => :codex
  }

  @binaries %{
    "opencode" => "opencode",
    "claude_code" => "claude",
    "codex" => "codex"
  }

  @default_timeout 15 * 60 * 1000

  @doc "The CLI binary a backend id invokes, or nil for unknown ids."
  def binary(backend) when is_binary(backend), do: Map.get(@binaries, backend)

  @doc """
  True when the backend's CLI binary is on PATH (or a test override forces it).
  """
  def available?(backend) when is_binary(backend) do
    case check_availability_override() do
      {:ok, forced} when is_boolean(forced) ->
        forced

      _ ->
        case Map.fetch(@binaries, backend) do
          {:ok, binary} -> System.find_executable(binary) != nil
          :error -> false
        end
    end
  end

  defp check_availability_override do
    Application.get_env(:home, :agentic_backend, [])
    |> Keyword.get(:force_available)
    |> case do
      nil -> :none
      value -> {:ok, value}
    end
  end

  def run(%Prompt{} = prompt, %Conversation{} = brief) do
    with :ok <- check_available(prompt.backend) do
      run_agentic(prompt, brief)
    end
  end

  defp run_agentic(%Prompt{} = prompt, %Conversation{} = brief) do
    user_prompt = resolve_user_prompt(prompt, brief)

    case timeout_wrapped(fn -> execute(prompt, user_prompt) end) do
      {:ok, %{text: text} = result} when is_binary(text) ->
        {:ok,
         %{
           content: text,
           parsed: nil,
           model_used: "#{prompt.backend}",
           cost_usd: Map.get(result, :cost, 0.0) || 0.0,
           metadata: run_metadata(prompt)
         }}

      {:ok, text} when is_binary(text) ->
        {:ok,
         %{
           content: text,
           parsed: nil,
           model_used: "#{prompt.backend}",
           cost_usd: 0.0,
           metadata: run_metadata(prompt)
         }}

      {:ok, other} ->
        {:error, {:malformed_agentic_response, other}}

      {:exit, reason} ->
        {:error, {:cli_crash, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute(prompt, user_prompt) do
    case run_callback() do
      nil -> run_cli(prompt, user_prompt)
      callback -> callback.(run_opts(prompt, user_prompt))
    end
  end

  defp run_metadata(prompt) do
    %{
      "backend" => prompt.backend,
      "profile" => to_string(Map.fetch!(@profiles, prompt.backend)),
      "title" => "brief:#{prompt.slug}"
    }
  end

  defp check_available(backend) do
    if available?(backend) do
      :ok
    else
      {:error, "backend #{inspect(backend)} unavailable: CLI not found on PATH"}
    end
  end

  # ── CLI invocation ───────────────────────────────────────────────────────

  # Per-backend CLI flags. All three take the prompt as the final
  # positional argument.
  defp cli_args(%Prompt{backend: "opencode"} = prompt) do
    ["run", "--title", "brief:#{prompt.slug}"] ++ model_args(prompt)
  end

  defp cli_args(%Prompt{backend: "codex"} = prompt), do: ["exec"] ++ model_args(prompt)
  defp cli_args(%Prompt{backend: "claude_code"}), do: ["-p"]

  defp model_args(%Prompt{model: model}) when is_binary(model) and model != "",
    do: ["-m", model]

  defp model_args(_prompt), do: []

  defp cli_script(%Prompt{} = prompt) do
    exe = prompt.backend |> binary() |> System.find_executable()
    args = cli_args(prompt) ++ [~S("$HOME_BRIEF_MSG")]

    "exec " <> Enum.join([exe | args], " ") <> " </dev/null"
  end

  defp run_cli(prompt, user_prompt) do
    workspace = workspace()
    File.mkdir_p!(workspace)
    message = full_message(prompt, user_prompt)

    case System.cmd("/bin/sh", ["-c", cli_script(prompt)],
           cd: workspace,
           env: %{"HOME_BRIEF_MSG" => message}
         ) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, code} ->
        {:error,
         {:exit_status, code,
          out |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.take(-5)}}
    end
  end

  defp full_message(prompt, user_prompt) do
    case prompt.system_prompt do
      nil -> user_prompt
      "" -> user_prompt
      system_prompt -> "#{system_prompt}\n\n---\n\n#{user_prompt}"
    end
  end

  # ── Knobs (configurable for tests / deployment) ─────────────────────────

  @doc """
  The callback that executes the agentic run, or nil to use the built-in
  CLI subprocess. Overridable per test: the callback receives the run opts
  keyword list and returns `{:ok, %{text: binary, cost: number}}`.
  """
  def run_callback do
    Application.get_env(:home, :agentic_backend, [])[:run_callback]
  end

  defp run_opts(prompt, user_prompt) do
    [
      profile: Map.fetch!(@profiles, prompt.backend),
      prompt: user_prompt,
      system_prompt: prompt.system_prompt,
      workspace: workspace(),
      session_id: "brief:#{prompt.slug}",
      cost_limit: cost_limit()
    ]
  end

  defp cost_limit, do: Application.get_env(:home, :agentic_backend, [])[:cost_limit] || 2.0

  defp workspace do
    Application.get_env(:home, :agentic_backend, [])[:workspace] || "/tmp/agentic-briefs"
  end

  defp timeout_wrapped(fun) do
    task = Task.async(fun)

    case Task.yield(task, @default_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :agentic_timeout}
    end
  end

  defp resolve_user_prompt(prompt, _brief) do
    now = DateTime.utc_now()
    date = DateTime.to_date(now)

    prompt.user_prompt
    |> String.replace("{{date}}", Date.to_string(date))
    |> String.replace("{{yesterday}}", Date.to_string(Date.add(date, -1)))
    |> String.replace("{{weekday}}", Calendar.strftime(date, "%A"))
  end
end
