defmodule PhoenixFlags.RouterTest do
  use ExUnit.Case, async: true

  defmodule OtherConfig do
    use PhoenixFlags,
      otp_app: :phoenix_flags,
      repo: PhoenixFlags.TestRepo

    flag("other_flag",
      type: :boolean,
      default: "false",
      category: "test",
      label: "Other Flag"
    )
  end

  test "flags_dashboard can be mounted twice with different configs and app_js" do
    # Compiling with two mounts used to emit duplicate pipeline/plug clauses,
    # making the second dashboard silently reuse the first mount's :app_js.
    {result, warnings} =
      Code.with_diagnostics(fn ->
        Code.compile_string("""
        defmodule PhoenixFlags.RouterTest.DoubleMountRouter do
          use Phoenix.Router

          import Phoenix.LiveView.Router
          import PhoenixFlags.Router

          pipeline :browser do
            plug(:accepts, ["html"])
            plug(:fetch_session)
            plug(:fetch_live_flash)
          end

          scope "/" do
            pipe_through(:browser)

            flags_dashboard("/flags", config: PhoenixFlags.TestConfig)

            flags_dashboard("/other-flags",
              config: PhoenixFlags.RouterTest.OtherConfig,
              app_js: "/assets/js/other.js"
            )
          end
        end
        """)
      end)

    assert is_list(result)
    assert warnings == []

    router = PhoenixFlags.RouterTest.DoubleMountRouter

    # Both routes exist and each carries its own config in the session MFA
    assert %{phoenix_live_view: {PhoenixFlags.UI.DashboardLive, :index, _, %{extra: extra_1}}} =
             Phoenix.Router.route_info(router, "GET", "/flags", "host")

    assert %{phoenix_live_view: {PhoenixFlags.UI.DashboardLive, :index, _, %{extra: extra_2}}} =
             Phoenix.Router.route_info(router, "GET", "/other-flags", "host")

    assert extra_1.session == {PhoenixFlags.Router, :__session__, [PhoenixFlags.TestConfig]}
    assert extra_2.session == {PhoenixFlags.Router, :__session__, [OtherConfig]}
  after
    :code.delete(PhoenixFlags.RouterTest.DoubleMountRouter)
    :code.purge(PhoenixFlags.RouterTest.DoubleMountRouter)
  end
end
