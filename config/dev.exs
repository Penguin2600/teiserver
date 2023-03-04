import Config

config :central, Central.Setup, key: "dev_key"

# Configure your database
config :central, Central.Repo,
  username: "teiserver_dev",
  password: "123456789",
  database: "teiserver_dev",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  timeout: 60_000

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we use it
# with webpack to recompile .js and .css sources.
config :central, CentralWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    # Start the esbuild watcher by calling Esbuild.install_and_run(:default, args)
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]},
    dark_sass: {
      DartSass,
      :install_and_run,
      [:dark, ~w(--embed-source-map --source-map-urls=absolute --watch)]
    },
    light_sass: {
      DartSass,
      :install_and_run,
      [:light, ~w(--embed-source-map --source-map-urls=absolute --watch)]
    }
  ]

config :dart_sass,
  version: "1.49.0",
  light: [
    args: ~w(scss/light.scss ../priv/static/assets/light.css),
    cd: Path.expand("../assets", __DIR__)
  ],
  dark: [
    args: ~w(scss/dark.scss ../priv/static/assets/dark.css),
    cd: Path.expand("../assets", __DIR__)
  ]

config :central, Teiserver,
  certs: [
    keyfile: "priv/certs/localhost.key",
    certfile: "priv/certs/localhost.crt",
    cacertfile: "priv/certs/localhost.crt"
  ],
  ports: [
    tcp: 8200,
    tls: 8201
  ],
  heartbeat_interval: nil,
  heartbeat_timeout: nil,
  enable_discord_bridge: false,
  enable_agent_mode: true,
  enable_hailstorm: true,
  use_geoip: true,
  accept_all_emails: true

# Watch static and templates for browser reloading.
config :central, CentralWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/central_web/(live|views)/.*(ex)$",
      ~r"lib/central_web/templates/.*(eex)$",
      ~r"lib/teiserver_web/(live|views)/.*(ex)$",
      ~r"lib/teiserver_web/templates/.*(eex)$"
    ]
  ]

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :central, Central.Communication.BlogFile, save_path: "/tmp/blog_files"

# Comment the below block to allow background jobs to happen in dev
config :central, Oban,
  queues: false,
  crontab: false

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

config :logger,
  backends: [
    {LoggerFileBackend, :error_log},
    {LoggerFileBackend, :info_log},
    :console
  ]

config :logger, :error_log,
  path: "/tmp/teiserver_error.log",
  format: "$time [$level] $metadata $message\n",
  metadata: [:request_id, :user_id],
  level: :error

config :logger, :info_log,
  path: "/tmp/teiserver_info.log",
  format: "$time [$level] $metadata $message\n",
  metadata: [:request_id, :user_id],
  level: :info

try do
  import_config "dev.secret.exs"
rescue
  _ ->
    nil
end
