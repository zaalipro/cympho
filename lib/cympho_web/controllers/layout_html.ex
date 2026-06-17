defmodule CymphoWeb.Layouts do
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Components.SwarmConfig,
    only: [default_mix_rows: 0, swarm_configuration: 1]

  embed_templates "layouts/*"
end
