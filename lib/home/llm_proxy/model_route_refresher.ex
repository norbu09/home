defmodule Home.LLMProxy.ModelRouteRefresher do
  @moduledoc """
  Periodically refreshes DB-backed model groups from OpenRouter's model index.
  """

  use GenServer

  alias Home.LLMProxy.ModelRouting

  require Logger

  @default_url "https://openrouter.ai/api/v1/models"
  @default_groups ["background-free", "free-coding", "openrouter-free-coding"]
  @default_interval_ms 24 * 60 * 60 * 1000
  @default_initial_delay_ms 15_000

  def start_link(opts \\ []) do
    if enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  def refresh do
    GenServer.call(__MODULE__, :refresh, 120_000)
  end

  def refresh_once(opts \\ []) do
    groups = Keyword.get(opts, :groups, groups())

    with {:ok, body} <- fetch_models(opts),
         routes when routes != [] <- routes_from_response(body) do
      results = Enum.map(groups, &ModelRouting.replace_model_group(&1, routes))
      {:ok, %{groups: groups, route_count: length(routes), results: results}}
    else
      [] -> {:error, :no_usable_openrouter_free_models}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :refresh, Keyword.get(opts, :initial_delay_ms, initial_delay_ms()))
    {:ok, %{interval_ms: Keyword.get(opts, :interval_ms, interval_ms())}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    result = refresh_once()
    {:reply, result, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    case refresh_once() do
      {:ok, %{groups: groups, route_count: route_count}} ->
        Logger.info(
          "OpenRouter free model route refresh complete: #{route_count} routes for #{Enum.join(groups, ", ")}"
        )

      {:error, reason} ->
        Logger.warning("OpenRouter free model route refresh failed: #{inspect(reason)}")
    end

    {:noreply, schedule_next(state)}
  end

  defp schedule_next(%{interval_ms: interval_ms} = state) do
    Process.send_after(self(), :refresh, interval_ms)
    state
  end

  defp fetch_models(opts) do
    fetch_fun = Keyword.get(opts, :fetch_fun)

    if is_function(fetch_fun, 0) do
      normalize_fetch_result(fetch_fun.())
    else
      request_openrouter(opts)
    end
  end

  defp request_openrouter(opts) do
    url = Keyword.get(opts, :url, url())
    timeout = Keyword.get(opts, :receive_timeout, receive_timeout())

    case Req.get(url,
           params: [
             sort: "coding-high-to-low",
             max_price: 0,
             supported_parameters: "tools",
             output_modalities: "text"
           ],
           receive_timeout: timeout
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp normalize_fetch_result({:ok, %{body: body}}), do: {:ok, body}
  defp normalize_fetch_result({:ok, body}), do: {:ok, body}
  defp normalize_fetch_result({:error, reason}), do: {:error, reason}
  defp normalize_fetch_result(other), do: {:error, {:unexpected_fetch_result, other}}

  defp routes_from_response(%{"data" => models}) when is_list(models) do
    models
    |> Enum.filter(&usable_free_model?/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {model, index} -> route_for(model, index) end)
  end

  defp routes_from_response(_body), do: []

  defp usable_free_model?(%{"id" => id} = model) when is_binary(id) do
    String.ends_with?(id, ":free") and
      zero_price?(model["pricing"]) and
      supports_tools?(model["supported_parameters"]) and
      text_output?(get_in(model, ["architecture", "output_modalities"]))
  end

  defp usable_free_model?(_model), do: false

  defp route_for(model, index) do
    %{
      provider: :openrouter,
      model: model["id"],
      order: 1,
      priority: index * 10,
      cost: %{input: 0.0, output: 0.0},
      notes: route_notes(model)
    }
  end

  defp route_notes(model) do
    name = model["name"] || model["id"]

    case model["expiration_date"] do
      nil -> "OpenRouter free coding/tool route: #{name}"
      "" -> "OpenRouter free coding/tool route: #{name}"
      expiration -> "OpenRouter free coding/tool route: #{name}; expires #{expiration}"
    end
  end

  defp zero_price?(%{"prompt" => prompt, "completion" => completion}) do
    zero_decimal?(prompt) and zero_decimal?(completion)
  end

  defp zero_price?(_pricing), do: false

  defp zero_decimal?(value) when value in [0, 0.0, "0", "0.0"], do: true

  defp zero_decimal?(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.equal?(decimal, Decimal.new(0))
      _ -> false
    end
  end

  defp zero_decimal?(_value), do: false

  defp supports_tools?(parameters) when is_list(parameters), do: "tools" in parameters
  defp supports_tools?(_parameters), do: false

  defp text_output?(modalities) when is_list(modalities), do: "text" in modalities
  defp text_output?(_modalities), do: false

  defp enabled? do
    config()
    |> Keyword.get(:enabled, true)
  end

  defp groups do
    config()
    |> Keyword.get(:groups, @default_groups)
  end

  defp url do
    config()
    |> Keyword.get(:url, @default_url)
  end

  defp interval_ms do
    config()
    |> Keyword.get(:interval_ms, @default_interval_ms)
  end

  defp initial_delay_ms do
    config()
    |> Keyword.get(:initial_delay_ms, @default_initial_delay_ms)
  end

  defp receive_timeout do
    config()
    |> Keyword.get(:receive_timeout, 60_000)
  end

  defp config, do: Application.get_env(:home, :llm_model_route_refresher, [])
end
