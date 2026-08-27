defmodule Home.LLMProxy.ModelRouteRefresherTest do
  use Home.DataCase, async: false

  alias Home.LLMProxy.{ModelRoute, ModelRouteRefresher, ModelRouting}

  test "refresh_once replaces configured groups with free OpenRouter coding routes" do
    assert {:ok, %{groups: ["background-free"], route_count: 2}} =
             ModelRouteRefresher.refresh_once(
               groups: ["background-free"],
               fetch_fun: fn ->
                 {:ok,
                  %{
                    "data" => [
                      free_model("z-ai/glm-5.2:free", "Z.ai: GLM 5.2 (free)"),
                      paid_model("anthropic/claude-sonnet-4.5"),
                      free_model("minimax/minimax-m3:free", "MiniMax: MiniMax M3 (free)")
                    ]
                  }}
               end
             )

    assert ModelRouting.resolve_chain("background-free") == [
             {:openrouter, "z-ai/glm-5.2:free"},
             {:openrouter, "minimax/minimax-m3:free"}
           ]

    assert [
             %ModelRoute{
               priority: 10,
               notes: "OpenRouter free coding/tool route: Z.ai: GLM 5.2 (free)"
             },
             %ModelRoute{
               priority: 20,
               notes: "OpenRouter free coding/tool route: MiniMax: MiniMax M3 (free)"
             }
           ] = ModelRoute.enabled_for_group("background-free")
  end

  test "refresh_once does not replace existing routes when no usable models are returned" do
    assert {:ok, _routes} =
             ModelRouting.replace_model_group("background-free", [
               %{provider: :openrouter, model: "existing/free:free", order: 1, priority: 10}
             ])

    assert {:error, :no_usable_openrouter_free_models} =
             ModelRouteRefresher.refresh_once(
               groups: ["background-free"],
               fetch_fun: fn ->
                 {:ok, %{"data" => [paid_model("anthropic/claude-sonnet-4.5")]}}
               end
             )

    assert [%ModelRoute{model: "existing/free:free"}] =
             ModelRoute.enabled_for_group("background-free")
  end

  defp free_model(id, name) do
    %{
      "id" => id,
      "name" => name,
      "pricing" => %{"prompt" => "0", "completion" => "0"},
      "supported_parameters" => ["max_tokens", "tools"],
      "architecture" => %{"output_modalities" => ["text"]},
      "expiration_date" => nil
    }
  end

  defp paid_model(id) do
    %{
      "id" => id,
      "name" => id,
      "pricing" => %{"prompt" => "3", "completion" => "15"},
      "supported_parameters" => ["max_tokens", "tools"],
      "architecture" => %{"output_modalities" => ["text"]},
      "expiration_date" => nil
    }
  end
end
