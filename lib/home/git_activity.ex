defmodule Home.GitActivity do
  @moduledoc "Bounded recent commit history across local project repositories."

  def recent(opts \\ []) do
    root = Keyword.get(opts, :root, config(:root, "/home/lenz/code"))
    days = Keyword.get(opts, :days, config(:lookback_days, 7))
    per_project = Keyword.get(opts, :per_project, config(:commits_per_project, 5))

    root
    |> repositories()
    |> Task.async_stream(&read_repository(&1, days, per_project),
      max_concurrency: 8,
      ordered: false,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, project}} -> [project]
      _ -> []
    end)
    |> Enum.reject(&(&1.commits == []))
    |> Enum.sort_by(& &1.latest_at, {:desc, DateTime})
  end

  defp repositories(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&{&1, Path.join(root, &1)})
        |> Enum.filter(fn {_name, path} -> File.exists?(Path.join(path, ".git")) end)
        |> Enum.group_by(fn {_name, path} -> common_git_directory(path) end)
        |> Enum.map(fn {_git_directory, repositories} ->
          Enum.max_by(repositories, fn {_name, path} -> File.dir?(Path.join(path, ".git")) end)
        end)

      _ ->
        []
    end
  end

  defp common_git_directory(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--git-common-dir"], stderr_to_stdout: true) do
      {directory, 0} -> directory |> String.trim() |> Path.expand(path)
      _ -> path
    end
  rescue
    _error -> path
  end

  defp read_repository({name, path}, days, per_project) do
    args = [
      "-C",
      path,
      "log",
      "--since=#{days} days ago",
      "--max-count=#{per_project}",
      "--date=iso-strict",
      "--pretty=format:%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1e"
    ]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        repository_url = repository_url(path)

        commits =
          output
          |> parse_commits(name)
          |> Enum.map(&Map.put(&1, :url, commit_url(repository_url, &1.sha)))

        {:ok,
         %{
           id: normalize_project(name),
           name: display_name(name),
           path: path,
           repository_url: repository_url,
           commits: commits,
           commit_count: length(commits),
           latest_at: commits |> Enum.map(& &1.committed_at) |> Enum.max(DateTime, fn -> nil end)
         }}

      _ ->
        {:error, :git_log_failed}
    end
  rescue
    _error -> {:error, :git_log_failed}
  end

  def github_url(remote) when is_binary(remote) do
    remote = String.trim(remote)

    cond do
      String.starts_with?(remote, "git@github.com:") ->
        remote |> String.replace_prefix("git@github.com:", "") |> github_https_url()

      String.starts_with?(remote, "ssh://git@github.com/") ->
        remote |> String.replace_prefix("ssh://git@github.com/", "") |> github_https_url()

      true ->
        case URI.parse(remote) do
          %URI{scheme: scheme, host: "github.com", path: path} when scheme in ["http", "https"] ->
            github_https_url(path)

          _other ->
            nil
        end
    end
  end

  def github_url(_remote), do: nil

  defp repository_url(path) do
    case System.cmd("git", ["-C", path, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {remote, 0} -> github_url(remote)
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp github_https_url(path) do
    repository = path |> String.trim("/") |> String.replace_suffix(".git", "")

    if repository == "", do: nil, else: "https://github.com/#{repository}"
  end

  defp commit_url(nil, _sha), do: nil
  defp commit_url(repository_url, sha), do: "#{repository_url}/commit/#{sha}"

  defp parse_commits(output, project) do
    output
    |> String.split(<<30>>, trim: true)
    |> Enum.flat_map(fn record ->
      case String.split(String.trim(record), <<31>>, parts: 5) do
        [sha, short_sha, author, committed_at, subject] ->
          case DateTime.from_iso8601(committed_at) do
            {:ok, datetime, _offset} ->
              [
                %{
                  id: "#{normalize_project(project)}-#{short_sha}",
                  sha: sha,
                  short_sha: short_sha,
                  author: author,
                  committed_at: datetime,
                  subject: subject
                }
              ]

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  defp display_name(name) do
    name
    |> String.replace(~r/[-_]+/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp normalize_project(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp config(key, default) do
    :home
    |> Application.get_env(:git_activity, [])
    |> Keyword.get(key, default)
  end
end
