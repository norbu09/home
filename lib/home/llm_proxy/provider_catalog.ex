defmodule Home.LLMProxy.ProviderCatalog do
  @moduledoc """
  Provider shortname registry for the local LiteLLM replacement.

  This intentionally mirrors the provider map used by kfos_agent while
  delegating the actual wire protocols to Agentic.
  """

  @providers %{
    anthropic: Agentic.LLM.Provider.Anthropic,
    groq: Agentic.LLM.Provider.Groq,
    kimi_coding: Agentic.LLM.Provider.KimiCoding,
    moonshot: Agentic.LLM.Provider.Moonshot,
    ollama: Agentic.LLM.Provider.Ollama,
    openai: Agentic.LLM.Provider.OpenAI,
    openrouter: Agentic.LLM.Provider.OpenRouter,
    zai: Agentic.LLM.Provider.Zai
  }

  @doc "Provider shortnames accepted in proxy model IDs."
  def names, do: Map.keys(@providers)

  @doc "Resolve a provider shortname to its Agentic provider module."
  def fetch(provider) when is_atom(provider), do: Map.fetch(@providers, provider)

  def fetch(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.to_existing_atom()
    |> fetch()
  rescue
    ArgumentError -> :error
  end

  @doc "All known models that can be advertised through `/v1/models`."
  def models do
    @providers
    |> Enum.flat_map(fn {provider, module} ->
      Enum.map(module.default_models(), fn model ->
        %{
          id: "#{provider}/#{model.id}",
          object: "model",
          owned_by: to_string(provider)
        }
      end)
    end)
    |> Enum.sort_by(& &1.id)
  end
end
