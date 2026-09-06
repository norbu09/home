defmodule Home.Brief.Prompt do
  @moduledoc """
  A pre-defined brief prompt: the system + user prompt pair, scheduling
  metadata, and category that shapes a scheduled LLM execution.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @categories ~w(calendar email infrastructure planning custom)

  schema "brief_prompts" do
    field :name, :string
    field :slug, :string
    field :category, :string, default: "custom"
    field :system_prompt, :string
    field :user_prompt, :string
    field :schedule, :map, default: %{}
    field :enabled, :boolean, default: true
    field :run_weekends, :boolean, default: false
    field :priority, :integer, default: 100
    field :model, :string
    field :metadata, :map, default: %{}

    has_many :briefs, Home.Brief.Conversation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(prompt, attrs) do
    prompt
    |> cast(attrs, [
      :name,
      :slug,
      :category,
      :system_prompt,
      :user_prompt,
      :schedule,
      :enabled,
      :run_weekends,
      :priority,
      :model,
      :metadata
    ])
    |> validate_required([:name, :slug, :system_prompt, :user_prompt])
    |> validate_inclusion(:category, @categories)
    |> validate_length(:name, max: 255)
    |> validate_length(:slug, max: 255)
  end
end
