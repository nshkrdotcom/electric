defmodule Electric.ShapeCache.Storage do
  import Electric.Replication.LogOffset, only: [is_log_offset_lt: 2]

  alias Electric.Shapes.Shape
  alias Electric.Shapes.Querying
  alias Electric.Replication.LogOffset

  defmodule Error do
    defexception [:message]
  end

  @type shape_handle :: Electric.ShapeCacheBehaviour.shape_handle()
  @type xmin :: Electric.ShapeCacheBehaviour.xmin()
  @type pg_snapshot :: %{
          xmin: pos_integer(),
          xmax: pos_integer(),
          xip_list: [pos_integer()],
          filter_txns?: boolean()
        }
  @type offset :: LogOffset.t()

  @type compiled_opts :: term()
  @type shape_opts :: term()

  @type storage :: {module(), compiled_opts()}
  @type shape_storage :: {module(), shape_opts()}

  @type operation_type :: :insert | :update | :delete
  @type log_item ::
          {LogOffset.t(), key :: String.t(), operation_type :: operation_type(),
           Querying.json_iodata()}
          | {:chunk_boundary | LogOffset.t()}
  @type log :: Enumerable.t(Querying.json_iodata())

  @type row :: list()

  @doc "Validate and initialise storage base configuration from application configuration"
  @callback shared_opts(term()) :: compiled_opts()

  @doc "Initialise shape-specific opts from the shared, global, configuration"
  @callback for_shape(shape_handle(), compiled_opts()) :: shape_opts()

  @doc "Start any processes required to run the storage backend"
  @callback start_link(shape_opts()) :: GenServer.on_start()

  @doc "Run any initial setup tasks"
  @callback initialise(shape_opts()) :: :ok

  @doc "Store the shape definition"
  @callback set_shape_definition(Shape.t(), shape_opts()) :: :ok

  @doc "Retrieve all stored shapes"
  @callback get_all_stored_shapes(compiled_opts()) ::
              {:ok, %{shape_handle() => Shape.t()}} | {:error, term()}

  @doc "Get the total disk usage for all shapes"
  @callback get_total_disk_usage(compiled_opts()) :: non_neg_integer()

  @doc """
  Get the current pg_snapshot and offset for the shape storage.

  If the instance is new, then it MUST return `{LogOffset.first(), nil}`.
  """
  @callback get_current_position(shape_opts()) ::
              {:ok, offset(), pg_snapshot() | nil} | {:error, term()}

  @callback set_pg_snapshot(pg_snapshot(), shape_opts()) :: :ok

  @doc "Check if snapshot for a given shape handle already exists"
  @callback snapshot_started?(shape_opts()) :: boolean()

  @doc """
  Make a new snapshot for a shape handle based on the meta information about the table and a stream of plain string rows

  Should raise an error if making the snapshot had failed for any reason.
  """
  @callback make_new_snapshot!(
              Querying.json_result_stream(),
              shape_opts()
            ) :: :ok

  @callback mark_snapshot_as_started(shape_opts()) :: :ok

  @doc """
  Append log items from one transaction to the log.

  Each storage implementation is responsible for handling transient errors
  using some retry strategy.

  If the backend fails to write within the expected time, or some other error
  occurs, then this should raise.
  """
  @callback append_to_log!(Enumerable.t(log_item()), shape_opts()) :: :ok | no_return()

  @doc "Get stream of the log for a shape since a given offset"
  @callback get_log_stream(offset :: LogOffset.t(), max_offset :: LogOffset.t(), shape_opts()) ::
              log()

  @doc """
  Get the last exclusive offset of the chunk starting from the given offset.

  If chunk has not finished accumulating, `nil` is returned.

  If chunk has finished accumulating, the last offset of the chunk is returned.
  """
  @callback get_chunk_end_log_offset(LogOffset.t(), shape_opts()) :: LogOffset.t() | nil

  @doc "Clean up snapshots/logs for a shape handle"
  @callback cleanup!(shape_opts()) :: :ok

  @doc """
  Clean up snapshots/logs for a shape handle by deleting whole directory.

  Does not require any extra storage processes to be running, but should only
  be used if the shape is known to not be in use to avoid concurrency issues.
  """
  @callback unsafe_cleanup!(shape_opts()) :: :ok

  @behaviour __MODULE__

  @last_log_offset LogOffset.last()

  @spec child_spec(shape_storage()) :: Supervisor.child_spec()
  def child_spec({module, shape_opts}) do
    %{
      id: module,
      start: {module, :start_link, [shape_opts]},
      restart: :transient
    }
  end

  @impl __MODULE__
  def shared_opts({module, opts}) do
    {module, module.shared_opts(opts)}
  end

  @impl __MODULE__
  def for_shape(shape_handle, {mod, opts}) do
    {mod, mod.for_shape(shape_handle, opts)}
  end

  @impl __MODULE__
  def start_link({mod, shape_opts}) do
    mod.start_link(shape_opts)
  end

  @impl __MODULE__
  def initialise({mod, shape_opts}) do
    mod.initialise(shape_opts)
  end

  @impl __MODULE__
  def set_shape_definition(shape, {mod, shape_opts}) do
    mod.set_shape_definition(shape, shape_opts)
  end

  @impl __MODULE__
  def get_all_stored_shapes({mod, opts}) do
    mod.get_all_stored_shapes(opts)
  end

  @impl __MODULE__
  def get_total_disk_usage({mod, opts}) do
    mod.get_total_disk_usage(opts)
  end

  @impl __MODULE__
  def get_current_position({mod, shape_opts}) do
    mod.get_current_position(shape_opts)
  end

  @impl __MODULE__
  def set_pg_snapshot(pg_snapshot, {mod, shape_opts}) do
    mod.set_pg_snapshot(pg_snapshot, shape_opts)
  end

  @impl __MODULE__
  def snapshot_started?({mod, shape_opts}) do
    mod.snapshot_started?(shape_opts)
  end

  @impl __MODULE__
  def make_new_snapshot!(stream, {mod, shape_opts}) do
    mod.make_new_snapshot!(stream, shape_opts)
  end

  @impl __MODULE__
  def mark_snapshot_as_started({mod, shape_opts}) do
    mod.mark_snapshot_as_started(shape_opts)
  end

  @impl __MODULE__
  def append_to_log!(log_items, {mod, shape_opts}) do
    mod.append_to_log!(log_items, shape_opts)
  end

  @impl __MODULE__
  def get_log_stream(offset, max_offset \\ @last_log_offset, {mod, shape_opts})
      when max_offset == @last_log_offset or not is_log_offset_lt(max_offset, offset) do
    mod.get_log_stream(offset, max_offset, shape_opts)
  end

  @impl __MODULE__
  def get_chunk_end_log_offset(offset, {mod, shape_opts}) do
    mod.get_chunk_end_log_offset(offset, shape_opts)
  end

  @impl __MODULE__
  def cleanup!({mod, shape_opts}) do
    mod.cleanup!(shape_opts)
  end

  @impl __MODULE__
  def unsafe_cleanup!({mod, shape_opts}) do
    mod.unsafe_cleanup!(shape_opts)
  end

  def compact({mod, shape_opts}), do: mod.compact(shape_opts)

  def compact({mod, shape_opts}, offset) when is_struct(offset, LogOffset),
    do: mod.compact(shape_opts, offset)
end
