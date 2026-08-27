defmodule HomeWeb.PageController do
  use HomeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
