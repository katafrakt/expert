import Config

case System.get_env("EXPERT_RELEASE_MODE", "plain") do
  "burrito" ->
    config :expert, arg_parser: {Burrito.Util.Args, :get_arguments, []}

  "plain" ->
    config :expert, arg_parser: {System, :argv, []}
end

import_config("#{config_env()}.exs")
