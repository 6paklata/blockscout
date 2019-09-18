defmodule Indexer.Temporary.MissingTokenTransfers do
  @moduledoc """
  Looks for a table `blocks_to_invalidate_missing_tt` specifing the number of
  blocks that need to be refetched. For each of them:
  - removes consensus from the block
  - deletes logs and token transfers of its transactions
  """

  use Indexer.Fetcher

  require Logger

  import Ecto.Query

  alias Ecto.Multi
  alias Explorer.Repo
  alias Explorer.Chain.{Block, Hash, Log, TokenTransfer, Transaction}
  alias Indexer.BufferedTask
  alias Indexer.Temporary.MissingTokenTransfers

  @behaviour BufferedTask

  @defaults [
    flush_interval: :timer.seconds(3),
    max_batch_size: 10,
    max_concurrency: 5,
    task_supervisor: Indexer.Temporary.MissingTokenTransfers.TaskSupervisor,
    metadata: [fetcher: :missing_token_transfers]
  ]

  @doc false
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  def child_spec([init_options, gen_server_options]) do
    merged_init_opts =
      @defaults
      |> Keyword.merge(init_options)
      |> Keyword.put(:state, {})

    Supervisor.child_spec({BufferedTask, [{__MODULE__, merged_init_opts}, gen_server_options]}, id: __MODULE__)
  end

  @impl BufferedTask
  def init(initial, reducer, _) do
    query =
      from(
        s in MissingTokenTransfers.Schema,
        where: is_nil(s.refetched) or not s.refetched,
        # goes from latest to newest
        order_by: [desc: s.block_number],
        select: s.block_number
      )

    {:ok, final} = Repo.stream_reduce(query, initial, &reducer.(&1, &2))

    final
  rescue
    postgrex_error in Postgrex.Error ->
      # if the table does not exist it just does no work
      case postgrex_error do
        %{postgres: %{code: :undefined_table}} -> {0, []}
        _ -> raise postgrex_error
      end
  end

  @impl BufferedTask
  def run(block_numbers, _) do
    # Enforce ShareLocks tables order (see docs: sharelocks.md)
    multi =
      Multi.new()
      |> Multi.run(:transaction_hashes, fn repo, _ ->
        query =
          from(
            t in Transaction,
            where: t.block_number in ^block_numbers,
            select: t.hash
          )

        hashes =
          query
          |> repo.all()
          |> Enum.map(fn h ->
            {:ok, hash_bytes} = Hash.Full.dump(h)
            hash_bytes
          end)

        {:ok, hashes}
      end)
      |> Multi.run(:remove_blocks_consensus, fn repo, _ ->
        query =
          from(
            block in Block,
            where: block.number in ^block_numbers,
            # Enforce Block ShareLocks order (see docs: sharelocks.md)
            order_by: [asc: block.hash],
            lock: "FOR UPDATE"
          )

        {_num, result} =
          repo.update_all(
            from(b in Block, join: s in subquery(query), on: b.hash == s.hash),
            set: [consensus: false]
          )

        {:ok, result}
      end)
      |> Multi.run(:remove_logs, fn repo, %{transaction_hashes: hashes} ->
        query =
          from(
            log in Log,
            join: t in fragment("(SELECT unnest(?::bytea[]) as hash)", ^hashes),
            on: t.hash == log.transaction_hash,
            # Enforce Log ShareLocks order (see docs: sharelocks.md)
            order_by: [asc: log.transaction_hash, asc: log.index],
            lock: "FOR UPDATE OF l0"
          )

        {_num, result} =
          repo.delete_all(from(l in Log, join: s in subquery(query), on: l.transaction_hash == s.transaction_hash))

        {:ok, result}
      end)
      |> Multi.run(:remove_token_transfers, fn repo, %{transaction_hashes: hashes} ->
        query =
          from(
            transfer in TokenTransfer,
            join: t in fragment("(SELECT unnest(?::bytea[]) as hash)", ^hashes),
            where: transfer.transaction_hash in ^hashes,
            # Enforce TokenTransfer ShareLocks order (see docs: sharelocks.md)
            order_by: [asc: transfer.transaction_hash, asc: transfer.log_index],
            lock: "FOR UPDATE OF t0"
          )

        {_num, result} =
          repo.delete_all(
            from(tt in TokenTransfer, join: s in subquery(query), on: tt.transaction_hash == s.transaction_hash)
          )

        {:ok, result}
      end)
      |> Multi.run(:update_schema_entries, fn repo, _ ->
        query =
          from(
            s in MissingTokenTransfers.Schema,
            order_by: [desc: s.block_number],
            lock: "FOR UPDATE"
          )

        {num, _res} =
          repo.update_all(
            from(dtt in MissingTokenTransfers.Schema, join: s in subquery(query), on: dtt.block_number == s.block_number),
            set: [refetched: true]
          )

        {:ok, num}
      end)

    try do
      multi
      |> Repo.transaction(timeout: :infinity)
      |> case do
        {:ok, _res} ->
          :ok

        {:error, error} ->
          Logger.error(fn -> ["Error while handling missing token transfers: ", inspect(error)] end)
          {:retry, block_numbers}
      end
    rescue
      postgrex_error in Postgrex.Error ->
        Logger.error(fn -> ["Error while handling missing token transfers: ", inspect(postgrex_error)] end)
        {:retry, block_numbers}
    end
  end

  defmodule Schema do
    @moduledoc """
    Schema for the table `blocks_to_invalidate_missing_tt`, used by the refetcher
    """

    use Explorer.Schema

    alias Explorer.Chain.Block

    @type t :: %__MODULE__{
            block_number: Block.block_number(),
            refetched: boolean() | nil
          }

    @primary_key false
    schema "blocks_to_invalidate_missing_tt" do
      field(:block_number, :integer)
      field(:refetched, :boolean)
    end

    def changeset(%__MODULE__{} = with_missing_tt, attrs) do
      with_missing_tt
      |> cast(attrs, [:block_number, :refetched])
      |> validate_required(:block_number)
    end
  end
end