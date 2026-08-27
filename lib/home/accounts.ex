defmodule Home.Accounts do
  use Ash.Domain,
    otp_app: :home

  resources do
    resource Home.Accounts.Token
    resource Home.Accounts.User
  end
end
