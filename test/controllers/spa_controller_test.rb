require "test_helper"
require "tmpdir"
require "fileutils"

class SpaControllerTest < ActionDispatch::IntegrationTest
  def setup
    @store = Dir.mktmpdir("client-store")
    @prev_store = ENV["CARBIDE_CLIENT_STORE"]
    ENV["CARBIDE_CLIENT_STORE"] = @store
  end

  def teardown
    if @prev_store.nil?
      ENV.delete("CARBIDE_CLIENT_STORE")
    else
      ENV["CARBIDE_CLIENT_STORE"] = @prev_store
    end
    FileUtils.remove_entry(@store) if @store && File.directory?(@store)
  end

  def write_build(name, sha, build_time:, marker: nil)
    dir = File.join(@store, name, sha)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "index.html"),
               "<html><head><title>t</title></head><body>#{marker || "#{name}/#{sha}"}</body></html>")
    File.write(File.join(dir, "manifest.json"), JSON.generate("build_time" => build_time))
  end

  test "serves the newest build of the default family with injected base href" do
    write_build("carbide2-client", "old", build_time: "2026-07-18T08:00:00Z", marker: "OLD_BUILD")
    write_build("carbide2-client", "new", build_time: "2026-07-18T20:00:00Z", marker: "NEW_BUILD")

    get "/"

    assert_response :success
    assert_includes @response.body, "NEW_BUILD"
    assert_not_includes @response.body, "OLD_BUILD"
    assert_includes @response.body, %(<base href="/">)
  end

  test "?client redirects to a clean URL and pins the exact build" do
    write_build("carbide2-client", "old", build_time: "2026-07-18T08:00:00Z", marker: "OLD_BUILD")
    write_build("carbide2-client", "new", build_time: "2026-07-18T20:00:00Z", marker: "NEW_BUILD")

    get "/", params: { client: "carbide2-client@old" }

    assert_response :see_other
    assert_redirected_to "/"
    assert_equal "carbide2-client@old", @response.cookies["carbide_client"]

    # The pin sticks on the follow-up load.
    get "/"
    assert_response :success
    assert_includes @response.body, "OLD_BUILD"
  end

  test "a family-only ?client tracks the newest build and clears any pin" do
    write_build("carbide2-client", "old", build_time: "2026-07-18T08:00:00Z", marker: "OLD_BUILD")
    write_build("carbide2-client", "new", build_time: "2026-07-18T20:00:00Z", marker: "NEW_BUILD")

    cookies["carbide_client"] = "carbide2-client@old"
    get "/", params: { client: "carbide2-client" }

    assert_response :see_other
    assert_redirected_to "/"
    # Pin cleared -> the follow-up load tracks the newest build.
    assert @response.cookies["carbide_client"].blank?
  end

  test "?client=latest is a family-agnostic escape hatch that clears a stale pin" do
    write_build("carbide2-client", "old", build_time: "2026-07-18T08:00:00Z", marker: "OLD_BUILD")
    write_build("carbide2-client", "new", build_time: "2026-07-18T20:00:00Z", marker: "NEW_BUILD")

    # A pin at a build whose picker is broken leaves no in-app way out; the
    # reset token clears it without the user knowing the family name.
    cookies["carbide_client"] = "carbide2-client@old"
    get "/", params: { client: "latest" }

    assert_response :see_other
    assert_redirected_to "/"
    assert @response.cookies["carbide_client"].blank?

    # The follow-up load now tracks the newest build again.
    get "/"
    assert_response :success
    assert_includes @response.body, "NEW_BUILD"
    assert_not_includes @response.body, "OLD_BUILD"
  end

  test "honours the pin cookie on subsequent loads" do
    write_build("carbide2-client", "old", build_time: "2026-07-18T08:00:00Z", marker: "OLD_BUILD")
    write_build("carbide2-client", "new", build_time: "2026-07-18T20:00:00Z", marker: "NEW_BUILD")

    cookies["carbide_client"] = "carbide2-client@old"
    get "/login"

    assert_response :success
    assert_includes @response.body, "OLD_BUILD"
  end

  test "ignores a pin cookie for a different family and serves the pod's own family" do
    # The carbide_client cookie is shared across the origin, so a workspace pod
    # can receive a pin the dashboard wrote for the control family. It must NOT
    # serve that build — it should fall back to the newest of its own family.
    write_build("carbide2-client", "ws", build_time: "2026-07-18T20:00:00Z", marker: "WORKSPACE_BUILD")
    write_build("carbide2-control", "ctl", build_time: "2026-07-18T21:00:00Z", marker: "DASHBOARD_BUILD")

    cookies["carbide_client"] = "carbide2-control@ctl"
    get "/"

    assert_response :success
    assert_includes @response.body, "WORKSPACE_BUILD"
    assert_not_includes @response.body, "DASHBOARD_BUILD"
  end

  test "an explicit ?client can still cross families but does not pin" do
    write_build("carbide2-client", "ws", build_time: "2026-07-18T20:00:00Z", marker: "WORKSPACE_BUILD")
    write_build("carbide2-control", "ctl", build_time: "2026-07-18T21:00:00Z", marker: "DASHBOARD_BUILD")

    get "/", params: { client: "carbide2-control@ctl" }

    # A cross-family pick resolves but is NOT pinned (only the pod's own family
    # is pinned), and we redirect to a clean URL; the follow-up load falls back
    # to this pod's own family.
    assert_response :see_other
    assert @response.cookies["carbide_client"].blank?

    get "/"
    assert_includes @response.body, "WORKSPACE_BUILD"
  end

  test "scopes the pin cookie to the mount path from X-Forwarded-Prefix" do
    write_build("carbide2-client", "c1", build_time: "2026-07-18T08:00:00Z", marker: "B")

    get "/", params: { client: "carbide2-client@c1" }, headers: { "X-Forwarded-Prefix" => "/w/2" }

    assert_response :see_other
    set_cookie = @response.headers["Set-Cookie"]
    set_cookie = set_cookie.join("\n") if set_cookie.is_a?(Array)
    assert_match %r{carbide_client=[^\n]*path=/w/2/}i, set_cookie
  end

  test "redirects back onto the mount path after a pick" do
    write_build("carbide2-client", "c1", build_time: "2026-07-18T08:00:00Z", marker: "B")

    get "/", params: { client: "carbide2-client@c1" }, headers: { "X-Forwarded-Prefix" => "/w/2" }

    assert_response :see_other
    assert_redirected_to "/w/2/"
  end

  test "injects the workspace prefix from X-Forwarded-Prefix" do
    write_build("carbide2-client", "c1", build_time: "2026-07-18T08:00:00Z", marker: "B")

    get "/", headers: { "X-Forwarded-Prefix" => "/w/2" }

    assert_response :success
    assert_includes @response.body, %(<base href="/w/2/">)
  end

  test "falls back to /about at root when no store and no baked bundle" do
    ENV["CARBIDE_CLIENT_STORE"] = File.join(@store, "does-not-exist")

    get "/"

    # Either the legacy baked bundle serves, or we redirect to /about.
    if File.exist?(Rails.root.join("spa", "index.html"))
      assert_response :success
    else
      assert_redirected_to "/about"
    end
  end
end
