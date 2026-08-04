require "test_helper"
require "tmpdir"
require "fileutils"

class ClientRegistryTest < ActiveSupport::TestCase
  def setup
    @store = Dir.mktmpdir("client-store")
  end

  def teardown
    FileUtils.remove_entry(@store) if @store && File.directory?(@store)
  end

  def write_build(name, sha, build_time:, label: nil, floors: nil)
    dir = File.join(@store, name, sha)
    FileUtils.mkdir_p(File.join(dir, "assets"))
    File.write(File.join(dir, "index.html"),
               "<html><head></head><body>#{name}/#{sha}</body></html>")
    manifest = { "build_time" => build_time }
    manifest["label"] = label if label
    manifest["floors"] = floors if floors
    File.write(File.join(dir, "manifest.json"), JSON.generate(manifest))
    dir
  end

  def registry(**opts) = ClientRegistry.new(store: @store, **opts)

  test "empty store reports nothing present" do
    assert_not registry.store_present? == false # dir exists but empty
    assert_empty registry.families
    assert_nil registry.newest
    assert_nil registry.resolve
  end

  test "families and builds are enumerated" do
    write_build("carbide2-client", "aaa111", build_time: "2026-07-18T10:00:00Z")
    write_build("carbide2-client", "bbb222", build_time: "2026-07-18T12:00:00Z")
    write_build("carbide2-mobile", "ccc333", build_time: "2026-07-18T09:00:00Z")

    assert_equal %w[carbide2-client carbide2-mobile], registry.families
    assert_equal 2, registry.builds("carbide2-client").size
  end

  test "builds are newest-first by build_time" do
    write_build("carbide2-client", "old", build_time: "2026-07-18T08:00:00Z")
    write_build("carbide2-client", "new", build_time: "2026-07-18T20:00:00Z")

    shas = registry.builds("carbide2-client").map(&:sha)
    assert_equal %w[new old], shas
    assert_equal "new", registry.newest("carbide2-client").sha
  end

  test "default family prefers carbide2-client" do
    write_build("carbide2-mobile", "m1", build_time: "2026-07-18T08:00:00Z")
    write_build("carbide2-client", "c1", build_time: "2026-07-18T08:00:00Z")

    assert_equal "carbide2-client", registry.default_family
    assert_equal "c1", registry.newest.sha
  end

  test "resolve by family, family@sha, and sha" do
    write_build("carbide2-client", "c1", build_time: "2026-07-18T08:00:00Z")
    write_build("carbide2-client", "c2", build_time: "2026-07-18T09:00:00Z")
    write_build("carbide2-mobile", "m1", build_time: "2026-07-18T08:00:00Z")

    assert_equal "c2", registry.resolve("carbide2-client").sha
    assert_equal "c1", registry.resolve("carbide2-client@c1").sha
    assert_equal "m1", registry.resolve("m1").sha
    assert_nil registry.resolve("carbide2-client@nope")
  end

  test "build exposes public base and manifest data" do
    write_build("carbide2-client", "c1", build_time: "2026-07-18T08:00:00Z",
                label: "rc2", floors: { "protocol" => 3 })
    b = registry.newest

    assert_equal "/clients/carbide2-client/c1/", b.public_base
    assert_equal "rc2", b.label
    assert_equal({ "protocol" => 3 }, b.floors)
    assert b.index_exist?
  end

  test "malformed manifest is tolerated" do
    dir = File.join(@store, "carbide2-client", "c1")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "index.html"), "<html><head></head></html>")
    File.write(File.join(dir, "manifest.json"), "{ not json")

    b = registry.newest
    assert_equal "c1", b.sha
    assert_equal "c1", b.label # falls back to sha
  end
end
