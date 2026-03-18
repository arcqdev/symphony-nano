defmodule SymphonyElixir.LiveE2ESSHTest do
  use SymphonyElixir.TestSupport

  @moduletag :live_e2e
  @moduletag timeout: 300_000
  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1",
                          do: "set SYMPHONY_RUN_LIVE_E2E=1 to enable the real Linear/Codex end-to-end test"
                        )

  @tag skip: @live_e2e_skip_reason
  test "creates a real Linear project and issue with an ssh worker" do
    SymphonyElixir.LiveE2ETest.run_live_issue_flow_for_test!(:ssh)
  end
end
