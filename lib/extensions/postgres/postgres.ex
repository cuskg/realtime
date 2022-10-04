defmodule Extensions.Postgres do
  @moduledoc false
  require Logger

  alias Extensions.Postgres
  alias Postgres.{Subscriptions, SubscriptionManagerTracker}

  def start_distributed(%{"region" => region, "id" => tenant} = args) do
    fly_region = Postgres.Regions.aws_to_fly(region)
    launch_node = launch_node(tenant, fly_region, node())

    Logger.warning(
      "Starting distributed postgres extension #{inspect(lauch_node: launch_node, region: region, fly_region: fly_region)}"
    )

    case :rpc.call(launch_node, Postgres, :start, [args], 30_000) do
      {:ok, _pid} ->
        :ok

      {_, error} ->
        Logger.error("Can't start Postgres ext #{inspect(error, pretty: true)}")
    end
  end

  @doc """
  Start db poller.

  """
  @spec start(map()) ::
          :ok | {:error, :already_started | :reserved}
  def start(args) do
    addrtype =
      case args["ip_version"] do
        6 ->
          :inet6

        _ ->
          :inet
      end

    args =
      Map.merge(args, %{
        "db_socket_opts" => [addrtype]
      })

    DynamicSupervisor.start_child(Postgres.DynamicSupervisor, %{
      id: args["id"],
      start: {Postgres.DynamicSupervisor, :start_link, [args]},
      restart: :transient
    })
  end

  @spec stop(String.t(), timeout()) :: :ok
  def stop(scope, timeout \\ :infinity) do
    case :syn.lookup(Extensions.Postgres.Sup, scope) do
      :undefined ->
        Logger.warning("Database supervisor not found for tenant #{scope}")

      {pid, _} ->
        DynamicSupervisor.stop(pid, :shutdown, timeout)
    end
  end

  @spec get_manager_conn(String.t()) :: nil | {:ok, pid(), pid()}
  def get_manager_conn(id) do
    Phoenix.Tracker.get_by_key(SubscriptionManagerTracker, "subscription_manager", id)
    |> case do
      [] ->
        nil

      [{_, %{manager_pid: pid, conn: conn}}] ->
        {:ok, pid, conn}
    end
  end

  def launch_node(tenant, fly_region, default) do
    case :syn.members(Postgres.RegionNodes, fly_region) do
      [_ | _] = regions_nodes ->
        member_count = Enum.count(regions_nodes)
        index = :erlang.phash2(tenant, member_count)
        {_, [node: launch_node]} = Enum.at(regions_nodes, index)
        launch_node

      _ ->
        Logger.warning("Didn't find launch_node, return default #{inspect(default)}")
        default
    end
  end

  def get_or_start_conn(args, retries \\ 5) do
    Enum.reduce_while(1..retries, nil, fn retry, acc ->
      get_manager_conn(args["id"])
      |> case do
        nil ->
          start_distributed(args)
          if retry > 1, do: Process.sleep(1_000)
          {:cont, acc}

        {:ok, _pid, _conn} = resp ->
          {:halt, resp}
      end
    end)
  end

  def create_subscription(conn, publication, opts, timeout \\ 5_000) do
    conn_node = node(conn)

    if conn_node !== node() do
      :rpc.call(conn_node, Subscriptions, :create, [conn, publication, opts], timeout)
    else
      Subscriptions.create(conn, publication, opts)
    end
  end

  def track_manager(id, pid, conn) do
    Phoenix.Tracker.track(SubscriptionManagerTracker, self(), "subscription_manager", id, %{
      conn: conn,
      manager_pid: pid
    })
  end
end
