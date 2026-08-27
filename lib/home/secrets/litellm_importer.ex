defmodule Home.Secrets.LiteLLMImporter do
  @moduledoc false

  alias Home.Secrets.Store

  @known_keys %{
    "OPENAI_API_KEY" => {"OPENAI_API_KEY", "OpenAI API key imported from LiteLLM"},
    "OPENROUTER_API_KEY" => {"OPENROUTER_API_KEY", "OpenRouter API key imported from LiteLLM"},
    "GROQ_API_KEY" => {"GROQ_API_KEY", "Groq API key imported from LiteLLM"},
    "ZAI_API_KEY" => {"ZAI_API_KEY", "z.ai API key imported from LiteLLM"},
    "Z_AI_API_KEY" => {"Z_AI_API_KEY", "z.ai API key imported from LiteLLM"},
    "ZAI_SUB_KEY" => {"ZAI_API_KEY", "z.ai subscription key imported from LiteLLM"},
    "MOONSHOT_API_KEY" => {"MOONSHOT_API_KEY", "Moonshot API key imported from LiteLLM"},
    "MOONSHOT_KEY" => {"MOONSHOT_KEY", "Moonshot API key imported from LiteLLM"},
    "KIMI_API_KEY" => {"KIMI_API_KEY", "Kimi API key imported from LiteLLM"},
    "KIMI_SUB_KEY" => {"KIMI_API_KEY", "Kimi subscription key imported from LiteLLM"},
    "DEEPINFRA_API_KEY" => {"DEEPINFRA_API_KEY", "DeepInfra API key imported from LiteLLM"},
    "NOVITA_API_KEY" => {"NOVITA_API_KEY", "Novita API key imported from LiteLLM"},
    "LITELLM_MASTER_KEY" => {"LITELLM_MASTER_KEY", "Former LiteLLM proxy master key"}
  }

  def import_file(path) do
    path
    |> File.read!()
    |> parse_env()
    |> Enum.flat_map(fn {source_key, value} ->
      case Map.get(@known_keys, source_key) do
        nil -> []
        {key, description} -> [{source_key, key, value, description}]
      end
    end)
    |> Enum.reduce({0, 0, []}, &import_secret/2)
  end

  defp import_secret({_source, _key, "", _description}, {imported, skipped, keys}) do
    {imported, skipped + 1, keys}
  end

  defp import_secret({_source, key, value, description}, {imported, skipped, keys}) do
    service = if key == "LITELLM_MASTER_KEY", do: "llm_proxy", else: "llm"

    case Store.put(service, key, value, description: description) do
      {:ok, _secret} -> {imported + 1, skipped, [{service, key} | keys]}
      {:error, _reason} -> {imported, skipped + 1, keys}
    end
  end

  defp parse_env(contents) do
    contents
    |> String.split("\n")
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        []

      String.contains?(line, "=") ->
        [key, value] = String.split(line, "=", parts: 2)
        [{String.trim(key), unquote_env_value(value)}]

      true ->
        []
    end
  end

  defp unquote_env_value(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end
end
