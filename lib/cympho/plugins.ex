defmodule Cympho.Plugins do
  @moduledoc """
  Namespace for the plugin runtime: `Cympho.Plugins.Registry`,
  `Cympho.Plugins.Supervisor`, `Cympho.Plugins.Worker`,
  `Cympho.Plugins.HostServices`, `Cympho.Plugins.PluginState`,
  `Cympho.Plugins.PluginLog`, and `Cympho.Plugins.PluginWebhook`.

  Plugin domain CRUD (list, create, update, delete, toggle, change) lives on
  `Cympho.Skills`. The duplicate CRUD surface that previously lived here was
  consolidated into `Cympho.Skills` in spec 02.
  """
end
