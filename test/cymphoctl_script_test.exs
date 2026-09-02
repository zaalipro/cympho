defmodule Cympho.CymphoctlScriptTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("..", __DIR__)

  for script <- [
        "cymphoctl_static_test.sh",
        "cymphoctl_test.sh",
        "deploy_source_attestation_test.sh",
        "deploy_env_transaction_behavior_test.sh",
        "deploy_env_transaction_test.sh",
        "deploy_lock_fencing_test.sh",
        "deploy_unit_rollback_test.sh"
      ] do
    @script script

    test "#{script} passes without root or systemd" do
      path = Path.join([@project_root, "test", "shell", @script])

      {output, status} =
        System.cmd("bash", [path],
          cd: @project_root,
          stderr_to_stdout: true,
          env: [{"HOME", System.tmp_dir!()}]
        )

      assert status == 0, output
      assert output =~ "ok -"
    end
  end
end
