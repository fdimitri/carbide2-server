require "test_helper"
require "tmpdir"
require "fileutils"

class Api::ClientsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @store = Dir.mktmpdir("client-store")
    @prev_store = ENV["CARBIDE_CLIENT_STORE"]
    ENV["CARBIDE_CLIENT_STORE"] = @store
  end

  def teardown
    @prev_store.nil? ? ENV.delete("CARBIDE_CLIENT_STORE") : ENV["CARBIDE_CLIENT_STORE"] = @prev_store
    FileUtils.remove_entry(@store) if @store && File.directory?(@store)
  end

  # ADR-015: auth is RS256 via JWKS; the server test env has no control signing
  # key, so stub the shared verifier for the duration of a request.
  def with_stubbed_auth
    JwtVerifier.stub(:verify, ->(token) { { 'user_email' => users(:test_user).email } }) { yield }
  end

  def write_build(name, sha, build_time:, label: nil)
    dir = File.join(@store, name, sha)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "index.html"), "<html><head></head></html>")
    manifest = { "build_time" => build_time }
    manifest["label"] = label if label
    File.write(File.join(dir, "manifest.json"), JSON.generate(manifest))
  end

  def token_for(_user)
    # Auth is stubbed in setup; any opaque bearer is fine.
    "test-token"
  end

  test "requires authentication" do
    get "/api/clients"
    assert_response :unauthorized
  end

  test "lists families and builds newest-first" do
    write_build("carbide2-client", "old", build_time: "2026-07-18T08:00:00Z")
    write_build("carbide2-client", "new", build_time: "2026-07-18T20:00:00Z", label: "rc2")

    with_stubbed_auth do
      get "/api/clients", headers: { "Authorization" => "Bearer #{token_for(users(:test_user))}" }
    end

    assert_response :success
    body = JSON.parse(@response.body)
    assert_equal "carbide2-client", body["default"]
    fam = body["families"].find { |f| f["name"] == "carbide2-client" }
    assert_equal "new", fam["default_sha"]
    assert_equal %w[new old], fam["builds"].map { |b| b["sha"] }
    assert_equal "rc2", fam["builds"].first["label"]
    assert_equal "/clients/carbide2-client/new/", fam["builds"].first["base"]
  end
end
