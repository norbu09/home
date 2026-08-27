defmodule Home.Secrets do
  use AshAuthentication.Secret

  def secret_for([:authentication, :tokens, :signing_secret], Home.Accounts.User, _opts, _context) do
    Application.fetch_env(:home, :token_signing_secret)
  end
end
