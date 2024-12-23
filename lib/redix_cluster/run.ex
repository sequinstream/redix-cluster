defmodule RedixCluster.Run do
  @moduledoc false

  @type command :: [binary]

  @spec command(command, Keyword.t()) :: {:ok, term} | {:error, term}
  def command(command, opts) do
    command
    |> parse_key_from_command()
    |> key_to_slot_hash()
    |> RedixCluster.SlotCache.get_pool()
    |> query_redis_pool(command, :command, opts)
  end

  @spec pipeline([command], Keyword.t()) :: {:ok, term} | {:error, term}
  def pipeline(pipeline, opts) do
    pipeline
    |> parse_keys_from_pipeline()
    |> keys_to_slot_hashs()
    |> is_same_slot_hashs()
    |> RedixCluster.SlotCache.get_pool()
    |> query_redis_pool(pipeline, :pipeline, opts)
  end

  @spec transaction([command], Keyword.t()) :: {:ok, term} | {:error, term}
  def transaction(pipeline, opts) do
    transaction = [["MULTI"]] ++ pipeline ++ [["EXEC"]]

    pipeline
    |> parse_keys_from_pipeline()
    |> keys_to_slot_hashs()
    |> is_same_slot_hashs()
    |> RedixCluster.SlotCache.get_pool()
    |> query_redis_pool(transaction, :pipeline, opts)
  end

  def flushdb() do
    {version, slots_maps} = RedixCluster.SlotCache.get_slot_maps()

    Enum.each(slots_maps, fn cluster ->
      case cluster == nil or cluster.node == nil do
        true -> nil
        false -> query_redis_pool({version, cluster.node.pool}, ~w(flushdb), :command, [])
      end
    end)

    {:ok, "OK"}
  end

  defp parse_key_from_command([["MULTI" | _] | rest]), do: parse_key_from_command(rest)

  defp parse_key_from_command([[cmd | args] | rest]) when is_binary(cmd),
    do: parse_key_from_command([cmd | args])

  defp parse_key_from_command([cmd | args]) when is_binary(cmd) do
    case String.downcase(cmd) do
      # Commands that don't need cluster keys - we'll let them pass through
      cmd when cmd in ["info", "config", "shutdown", "slaveof"] ->
        nil

      # Commands that use the second argument as key
      "bitop" ->
        Enum.at(args, 1)

      "object" ->
        Enum.at(args, 1)

      "xgroup" ->
        Enum.at(args, 1)

      "xinfo" ->
        Enum.at(args, 1)

      "zdiff" ->
        Enum.at(args, 1)

      "zinter" ->
        Enum.at(args, 1)

      "zunion" ->
        Enum.at(args, 1)

      # Commands that use the third argument as key
      cmd when cmd in ["eval", "evalsha"] ->
        Enum.at(args, 2)

      # Commands with special handling
      "xread" ->
        find_arg_after_keyword("streams", args)

      "xreadgroup" ->
        find_arg_after_keyword("streams", args)

      "memory" ->
        handle_memory_command(args)

      # Default case - use first argument as key
      _ ->
        args |> List.first() |> to_string()
    end
  end

  defp parse_key_from_command(_), do: nil

  # Helper functions for special cases
  defp find_arg_after_keyword(keyword, args) do
    case Enum.find_index(args, &(String.downcase(to_string(&1)) == keyword)) do
      nil -> nil
      idx -> Enum.at(args, idx + 1)
    end
  end

  defp handle_memory_command([subcmd | args]) do
    case String.downcase(to_string(subcmd)) do
      "usage" -> List.first(args)
      _ -> nil
    end
  end

  defp handle_memory_command(_), do: nil

  defp parse_keys_from_pipeline(pipeline) do
    case get_command_keys(pipeline) do
      {:error, _} = error -> error
      keys -> for [term1, term2] <- keys, do: verify_command_key(term1, term2)
    end
  end

  def key_to_slot_hash({:error, _} = error), do: error

  def key_to_slot_hash(key) do
    case Regex.run(~r/{\S+}/, key) do
      nil ->
        RedixCluster.Hash.hash(key)

      [tohash_key] ->
        tohash_key
        |> String.trim_leading("{")
        |> String.trim_trailing("}")
        |> RedixCluster.Hash.hash()
    end
  end

  defp keys_to_slot_hashs({:error, _} = error), do: error

  defp keys_to_slot_hashs(keys) do
    for key <- keys, do: key_to_slot_hash(key)
  end

  defp is_same_slot_hashs({:error, _} = error), do: error

  defp is_same_slot_hashs([hash | _] = hashs) do
    case Enum.all?(hashs, fn h -> h != nil and h == hash end) do
      false -> {:error, :key_must_same_slot}
      true -> hash
    end
  end

  def get_pool_by_slot({:error, _} = error, _, _, _), do: error

  def get_pool_by_slot(slot, slots_maps, slots, version) do
    index = Enum.at(slots, slot)
    cluster = Enum.at(slots_maps, index - 1)

    case cluster == nil or cluster.node == nil do
      true -> {version, nil}
      false -> {version, cluster.node.pool}
    end
  end

  defp query_redis_pool({:error, _} = error, _command, _opts, _type), do: error

  defp query_redis_pool({version, nil}, _command, _opts, _type) do
    RedixCluster.Monitor.refresh_mapping(version)
    {:error, :retry}
  end

  defp query_redis_pool({version, pool_name}, command, type, opts) do
    try do
      pool_name
      |> :poolboy.transaction(fn worker -> GenServer.call(worker, {type, command, opts}) end)
      |> parse_trans_result({version, pool_name}, command, type, opts)
    catch
      :exit, reason ->
        RedixCluster.Monitor.refresh_mapping(version)
        {:error, :retry}
    end
  end

  defp parse_trans_result(
         {:error, %Redix.Error{message: <<"ASK", redirectioninfo::binary>>}},
         {version, _pool_name},
         command,
         type,
         opts
       ) do
    [_, _slot, host_info] = Regex.split(~r/\s+/, redirectioninfo)
    [host, port] = Regex.split(~r/:/, host_info)
    RedixCluster.Pools.Supervisor.new_pool(host, port)
    pool_name = ["Pool", host, ":", port] |> Enum.join() |> String.to_atom()
    query_redis_pool({version, pool_name}, command, type, opts)
  end

  defp parse_trans_result(
         {:error, %Redix.Error{message: <<"MOVED", _redirectioninfo::binary>>}},
         {version, _pool_name},
         _command,
         _type,
         _opts
       ) do
    RedixCluster.Monitor.refresh_mapping(version)
    {:error, :retry}
  end

  defp parse_trans_result({:error, :no_connection}, {version, _pool_name}, _command, _type, _opts) do
    RedixCluster.Monitor.refresh_mapping(version)
    {:error, :retry}
  end

  defp parse_trans_result({:error, :closed}, {version, _pool_name}, _command, _type, _opts) do
    RedixCluster.Monitor.refresh_mapping(version)
    {:error, :retry}
  end

  defp parse_trans_result(
         {:error, %Redix.ConnectionError{} = error},
         {version, _pool_name},
         _command,
         _type,
         _opts
       ) do
    RedixCluster.Monitor.refresh_mapping(version)
    {:error, :retry}
  end

  defp parse_trans_result(
         {:error, %Redix.Error{message: <<"CLUSTERDOWN", _::binary>>}},
         {version, _pool_name},
         _command,
         _type,
         _opts
       ) do
    RedixCluster.Monitor.refresh_mapping(version)
    {:error, :retry}
  end

  defp parse_trans_result(payload, _, _, _, _), do: payload

  defp verify_command_key(term1, term2, rest \\ []) do
    case term1 |> to_string |> String.downcase() do
      "object" ->
        rest |> Enum.at(0)

      cmd when cmd in ["eval", "evalsha"] ->
        rest |> Enum.at(1)

      cmd ->
        cmd |> forbid_harmful_command(term2)
    end
  end

  defp forbid_harmful_command("info", _), do: {:error, :invalid_cluster_command}
  defp forbid_harmful_command("config", _), do: {:error, :invalid_cluster_command}
  defp forbid_harmful_command("shutdown", _), do: {:error, :invalid_cluster_command}
  defp forbid_harmful_command("slaveof", _), do: {:error, :invalid_cluster_command}
  defp forbid_harmful_command(_, key), do: to_string(key)

  defp get_command_keys([["MULTI"] | _]), do: {:error, :no_support_transaction}
  defp get_command_keys(commands), do: make_cmd_key(commands, [])

  defp make_cmd_key([], acc), do: acc
  defp make_cmd_key([[x, y | _] | rest], acc), do: make_cmd_key(rest, [[x, y] | acc])
  defp make_cmd_key([_ | rest], acc), do: make_cmd_key(rest, acc)
end
