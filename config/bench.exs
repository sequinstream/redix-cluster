import Config

config :redix_cluster,
  cluster_nodes: [
    %{host: "127.0.0.1", port: 7000},
    %{host: "127.0.0.1", port: 7001},
    %{host: "127.0.0.1", port: 7002}
  ],
  pool_size: 5,
  pool_max_overflow: 0,

  # connection_opts
  socket_opts: [],
  backoff_initial: 2000,
  backoff_max: 2000

config :eredis_cluster,
  init_nodes: [{~c"127.0.0.1", 7000}, {~c"127.0.0.1", 7001}, {~c"127.0.0.1", 7002}],
  pool_size: 5,
  pool_max_overflow: 0
