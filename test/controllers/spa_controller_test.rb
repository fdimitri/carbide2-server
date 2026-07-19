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

  test "?client selects a specific build and pins a cookie" do
    write_build("carbide2-client", "old", build_time: "2026-07-18T08:00:00Z", marker: "OLD_BUILD")
    write_build("carbide2-client", "new", build_time: "2026-07-18T20:00:00Z", marker: "NEW_BUILD")

    get "/", params: { client: "carbide2-client@old" }

    assert_response :success
    assert_includes @response.body, "OLD_BUILD"
    assert_equal "carbide2-client@old", @response.cookies["carbide_client"]
  end

  test "honours the pin cookie on subsequent loads" do
    write_build("carbide2-client", "old", build_time: "2026-07-18T08:00:00Z", marker: "OLD_BUILD")
    write_build("carbide2-client", "new", build_time: "2026-07-18T20:00:00Z", marker: "NEW_BUILD")

    cookies["carbide_client"] = "carbide2-client@old"
    get "/login"

    assert_response :success
    assert_includes @response.body, "OLD_BUILD"
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
