defmodule Home.Brief.Conversation do
  @moduledoc """
  One brief execution: the LLM outcome, status, costs, and the human
  reference number (`BRF-XXXX`) used to cite it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed reviewed dismissed)

  schema "briefs" do
    field :status, :string, default: "pending"
    field :outcome, :string
    field :summary, :string
    field :next_steps, {:array, :string}, default: []
    field :action_items, {:array, :map}, default: []
    field :reviewed_at, :utc_datetime_usec
    field :review_notes, :string
    field :error, :string
    field :scheduled_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :model_used, :string
    field :cost_usd, :float
    field :number, :string
    field :metadata, :map, default: %{}

    belongs_to :prompt, Home.Brief.Prompt, foreign_key: :prompt_id

    belongs_to :retried_from, __MODULE__,
      foreign_key: :retried_from_id,
      define_field: false

    field :retried_from_id, :binary_id

    has_many :messages, Home.Brief.Message, foreign_key: :brief_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(brief, attrs) do
    brief
    |> cast(attrs, [
      :prompt_id,
      :status,
      :outcome,
      :summary,
      :next_steps,
      :action_items,
      :reviewed_at,
      :review_notes,
      :error,
      :scheduled_at,
      :completed_at,
      :model_used,
      :cost_usd,
      :number,
      :retried_from_id,
      :metadata
    ])
    |> validate_required([:prompt_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:number, ~r/\ABRF-\d{4}\z/)
  end
end
