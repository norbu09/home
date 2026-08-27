defmodule Mix.Tasks.LlmProxy.SeedModelRoutes do
  @moduledoc """
  Seed DB-backed LLM proxy model routes from `config :home, :llm_proxy`.

      mix llm_proxy.seed_model_routes
  """

  use Mix.Task

  @shortdoc "Seed LLM proxy model routes from config"

  @impl true
  def run(args) do
    case args do
      [] ->
        Mix.Task.run("app.start")

        groups =
          :home
          |> Application.get_env(:llm_proxy, [])
          |> Keyword.get(:model_groups, %{})

        results = Home.LLMProxy.ModelRouting.seed_config_model_groups()

        Enum.each(Enum.zip(Map.keys(groups), results), fn {group, result} ->
          case result do
            {:ok, routes} ->
              Mix.shell().info("seeded #{group}: #{length(routes)} routes")

            {:error, reason} ->
              Mix.raise("failed to seed #{group}: #{inspect(reason)}")
          end
        end)

        Mix.shell().info("LLM proxy model route seed complete")

      extra ->
        Mix.raise("unexpected arguments: #{Enum.join(extra, " ")}")
    end
  end
end
