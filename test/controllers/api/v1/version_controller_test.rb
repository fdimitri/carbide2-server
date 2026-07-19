require "test_helper"

class Api::V1::VersionControllerTest < ActionDispatch::IntegrationTest
  ENV_KEYS = %w[CARBIDE_META_SHA CARBIDE_SERVER_SHA CARBIDE_WORKER_SHA CARBIDE_BUILD_TIME].freeze

  def setup
    @prev = ENV_KEYS.to_h { |k| [k, ENV[k]] }
  end

  def teardown
    @prev.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def set_env(**vals)
    vals.each { |k, v| ENV[k.to_s.upcase] = v }
  end

  test "common/version reports service and component SHAs from the image env" do
    set_env(CARBIDE_META_SHA: "meta123456ab", CARBIDE_SERVER_SHA: "srv123456abc",
            CARBIDE_WORKER_SHA: "wrk123456abc", CARBIDE_BUILD_TIME: "2026-07-18T00:00:00Z")

    get "/api/v1/common/version"

    assert_response :success
    body = JSON.parse(@response.body)
    assert_equal "server", body["service"]
    assert_equal "srv123456abc", body["sha"]
    assert_equal "2026-07-18T00:00:00Z", body["built_at"]
    assert_equal({ "meta" => "meta123456ab", "server" => "srv123456abc", "worker" => "wrk123456abc" },
                 body["components"])
  end

  test "common/version treats the 'unknown' ARG default and blanks as absent" do
    set_env(CARBIDE_META_SHA: "unknown", CARBIDE_SERVER_SHA: "", CARBIDE_WORKER_SHA: "wrk123456abc")
    ENV.delete("CARBIDE_BUILD_TIME")

    get "/api/v1/common/version"

    assert_response :success
    body = JSON.parse(@response.body)
    assert_nil body["sha"]
    assert_nil body["built_at"]
    assert_equal({ "worker" => "wrk123456abc" }, body["components"])
  end

  test "server/version adds server-only runtime detail" do
    get "/api/v1/server/version"

    assert_response :success
    body = JSON.parse(@response.body)
    assert_equal "server", body["service"]
    assert_equal RUBY_VERSION, body["ruby"]
    assert_equal Rails.env.to_s, body["rails_env"]
  end

  test "version endpoints require no authentication" do
    get "/api/v1/common/version"
    assert_response :success
  end
end
