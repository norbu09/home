defmodule Home.Cognee.Client do
  @moduledoc "Reads dataset activity signals from the local Cognee API."

  require Logger

  def fetch_dataset_stats do
    now = DateTime.utc_now()

    with {:ok, datasets} <- get_json("/api/v1/datasets") do
      {stats, errors} =
        datasets
        |> Task.async_stream(&fetch_dataset(&1, now),
          max_concurrency: 5,
          ordered: false,
          timeout: request_timeout(),
          on_timeout: :kill_task
        )
        |> Enum.reduce({[], 0}, fn
          {:ok, {:ok, stat}}, {stats, errors} -> {[stat | stats], errors}
          _, {stats, errors} -> {stats, errors + 1}
        end)

      if stats == [] and datasets != [] do
        {:error, :dataset_reads_failed}
      else
        {:ok, Enum.sort_by(stats, & &1.dataset_name), errors}
      end
    end
  end

  defp fetch_dataset(%{"id" => id, "name" => name}, now) do
    with {:ok, items} <- get_json("/api/v1/datasets/#{id}/data") do
      activity_times = Enum.flat_map(items, &activity_times/1)

      {:ok,
       %{
         dataset_id: id,
         dataset_name: name,
         item_count: length(items),
         recent_day_count: recent_count(items, now, 24 * 60 * 60),
         recent_week_count: recent_count(items, now, 7 * 24 * 60 * 60),
         latest_activity_at: Enum.max(activity_times, DateTime, fn -> nil end),
         captured_at: now
       }}
    end
  end

  defp fetch_dataset(_, _now), do: {:error, :invalid_dataset}

  defp recent_count(items, now, seconds) do
    threshold = DateTime.add(now, -seconds, :second)

    Enum.count(items, fn item ->
      case item_datetime(item, "createdAt") do
        %DateTime{} = created_at -> DateTime.compare(created_at, threshold) in [:gt, :eq]
        _ -> false
      end
    end)
  end

  defp activity_times(item) do
    [item_datetime(item, "updatedAt"), item_datetime(item, "createdAt")]
    |> Enum.reject(&is_nil/1)
  end

  defp item_datetime(item, key) do
    case Map.get(item, key) do
      value when is_binary(value) -> parse_datetime(value)
      _ -> nil
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, :missing_offset} ->
        with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
             {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
          datetime
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp get_json(path) do
    case Req.get(endpoint() <> path, receive_timeout: request_timeout()) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.debug("Cognee insight request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp endpoint do
    :home
    |> Application.get_env(:cognee_insights, [])
    |> Keyword.get(:endpoint, "http://127.0.0.1:8000")
    |> String.trim_trailing("/")
  end

  defp request_timeout do
    :home
    |> Application.get_env(:cognee_insights, [])
    |> Keyword.get(:request_timeout_ms, 15_000)
  end
end
