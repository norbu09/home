defmodule Home.Secrets.Store do
  @moduledoc """
  Cloak-encrypted local secret store.

  LLM provider keys live under service `"llm"` with the provider env var as
  the key, e.g. `llm/OPENROUTER_API_KEY`.
  """

  import Ecto.Query

  alias Home.Repo
  alias Home.Secrets.Secret
  alias Home.Vault

  require Logger

  @llm_service "llm"

  def put(service, key, value, opts \\ [])
      when is_binary(service) and is_binary(key) and is_binary(value) do
    encrypted = Vault.encrypt!(value)

    attrs = %{
      service: service,
      key: key,
      encrypted_value: encrypted,
      description: Keyword.get(opts, :description),
      is_active: Keyword.get(opts, :is_active, true)
    }

    case get_record(service, key) do
      nil ->
        %Secret{}
        |> Secret.changeset(attrs)
        |> Repo.insert()

      %Secret{} = secret ->
        secret
        |> Secret.changeset(Map.reject(attrs, fn {_key, value} -> is_nil(value) end))
        |> Repo.update()
    end
  end

  def get(service, key) when is_binary(service) and is_binary(key) do
    case get_record(service, key) do
      %Secret{is_active: true, encrypted_value: encrypted} when is_binary(encrypted) ->
        case Vault.decrypt(encrypted) do
          {:ok, value} when is_binary(value) -> {:ok, value}
          _ -> from_env(service, key, :unavailable)
        end

      %Secret{} ->
        {:error, :inactive}

      nil ->
        from_env(service, key, :not_found)
    end
  rescue
    e ->
      Logger.error("Secrets.Store: read failed for #{service}/#{key}: #{Exception.message(e)}")
      from_env(service, key, :unavailable)
  end

  def get!(service, key) do
    case get(service, key) do
      {:ok, value} -> value
      {:error, reason} -> raise "Secret unavailable: #{service}/#{key} (#{reason})"
    end
  end

  def get_env(env_var) when is_binary(env_var), do: get(@llm_service, env_var)

  def get_first_env(env_vars) when is_list(env_vars) do
    Enum.find_value(env_vars, fn env_var ->
      case get_env(env_var) do
        {:ok, value} -> {:ok, value}
        _ -> nil
      end
    end) || {:error, :not_found}
  end

  def env_available?(env_var) when is_binary(env_var) do
    match?({:ok, value} when is_binary(value) and value != "", get_env(env_var))
  end

  def list(service) when is_binary(service) do
    Secret
    |> where([s], s.service == ^service)
    |> order_by([s], asc: s.key)
    |> Repo.all()
  end

  def list_all do
    Secret
    |> order_by([s], asc: s.service, asc: s.key)
    |> Repo.all()
  end

  def set_active(id, is_active) when is_binary(id) and is_boolean(is_active) do
    case Repo.get(Secret, id) do
      nil -> {:error, :not_found}
      secret -> secret |> Secret.changeset(%{is_active: is_active}) |> Repo.update()
    end
  end

  def delete(id) when is_binary(id) do
    case Repo.get(Secret, id) do
      nil -> {:error, :not_found}
      secret -> Repo.delete(secret)
    end
  end

  defp get_record(service, key), do: Repo.get_by(Secret, service: service, key: key)

  defp from_env("llm", key, reason), do: from_env_key(key, reason)

  defp from_env(service, key, reason) do
    service
    |> Kernel.<>("_#{key}")
    |> String.upcase()
    |> from_env_key(reason)
  end

  defp from_env_key(env_key, reason) do
    case System.get_env(env_key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, reason}
    end
  end
end
