# Registry of built SPA clients available to this workspace pod.
#
# The Decider serves clients from a content-addressed store laid out as
#   <family>/<sha>/{index.html, manifest.json, assets/*}
# where <family> is a client name (e.g. "carbide2-client", "carbide2-mobile")
# and <sha> is the build's content address. Each build is compiled with an
# absolute Vite base of "/clients/<family>/<sha>/", so its asset URLs are
# already absolute and resolve to the static tier regardless of which workspace
# the shell is served from. This registry only has to (a) enumerate the
# available builds and (b) resolve a pinned build so SpaController can read and
# serve its index.html.
#
# Two backends sit behind the same interface:
#   - FsBackend (tests): the store lives under public/clients so
#     ActionDispatch::Static serves the assets on the same origin. Selected by
#     the `store:` kwarg or CARBIDE_CLIENT_STORE.
#   - HttpBackend (in-cluster): the store is the MinIO static tier reached over
#     HTTP. Enumeration reads a `registry.json` index object (maintained by
#     scripts/build-client), and index.html is fetched per build. Selected by
#     the `tier_url:` kwarg or CARBIDE_CLIENT_TIER_URL, e.g.
#     "http://minio.carbide-system.svc.cluster.local:9000/clients".
# The public URL contract "/clients/<family>/<sha>/" is identical either way.
class ClientRegistry
  # A single resolved build. Reads through the backend that produced it.
  Build = Struct.new(:name, :sha, :manifest, :backend, keyword_init: true) do
    # Absolute, origin-relative base under which this build's assets live.
    def public_base = "/clients/#{name}/#{sha}/"
    def label        = manifest["label"].presence || sha
    def build_time   = manifest["build_time"]
    def commit_time  = manifest["commit_time"]
    def floors       = manifest["floors"] || {}
    def index_exist? = backend.index_exist?(name, sha)
    def read_index   = backend.read_index(name, sha)

    def as_json_h
      { name:, sha:, label:, build_time:, commit_time:, base: public_base, floors: }
    end
  end

  DEFAULT_FAMILY = "carbide2-client"

  def initialize(store: nil, tier_url: nil, default_family: nil)
    @default_family = default_family || ENV["CARBIDE_CLIENT_DEFAULT"].presence
    store    ||= ENV["CARBIDE_CLIENT_STORE"].presence
    tier_url ||= ENV["CARBIDE_CLIENT_TIER_URL"].presence

    # An explicit/env store always means the local FS backend (dev + tests).
    # Otherwise a tier URL selects the in-cluster HTTP backend. With neither,
    # fall back to the conventional public/clients store.
    @backend =
      if store.nil? && tier_url
        HttpBackend.new(tier_url)
      else
        FsBackend.new(store || Rails.root.join("public", "clients").to_s)
      end
  end

  def store_present? = @backend.available?

  # All builds across all families (memoized per instance so a single request
  # hits the backend once).
  def all_builds
    @all_builds ||= @backend.entries.map do |e|
      Build.new(name: e[:name], sha: e[:sha], manifest: e[:manifest], backend: @backend)
    end
  end

  # Client family names present in the store (sorted).
  def families
    all_builds.map(&:name).uniq.sort
  end

  # Builds for a family, newest first by git commit time (falling back to
  # build_time for manifests built before commit_time existed), then sha.
  def builds(name)
    all_builds.select { |b| b.name == name.to_s }
              .sort_by { |b| [(b.commit_time.presence || b.build_time).to_s, b.sha] }
              .reverse
  end

  def build_for(name, sha)
    all_builds.find { |b| b.name == name.to_s && b.sha == sha.to_s }
  end

  # The family to serve when no explicit pin is given.
  def default_family
    fams = families
    return @default_family if @default_family && fams.include?(@default_family)
    return DEFAULT_FAMILY if fams.include?(DEFAULT_FAMILY)

    fams.first
  end

  def newest(name = default_family)
    return nil if name.nil?

    builds(name).first
  end

  # Resolve a pin spec into a concrete Build (or nil).
  #   nil / ""      -> newest build of the default family
  #   "family"      -> newest build of that family
  #   "family@sha"  -> that exact build
  #   "sha"         -> a build with that sha (prefix match) in any family
  def resolve(spec = nil)
    return newest if spec.blank?

    if spec.include?("@")
      name, sha = spec.split("@", 2)
      return build_for(name, sha)
    end

    return newest(spec) if families.include?(spec)

    all_builds.find { |b| b.sha == spec || b.sha.start_with?(spec) }
  end

  # Local filesystem store: <store>/<family>/<sha>/{index.html,manifest.json}.
  class FsBackend
    def initialize(store)
      @store = store.to_s
    end

    def available? = File.directory?(@store)

    def entries
      return [] unless available?

      Dir.children(@store).select { |c| File.directory?(File.join(@store, c)) }.flat_map do |name|
        fdir = File.join(@store, name)
        Dir.children(fdir).select { |s| File.directory?(File.join(fdir, s)) }.map do |sha|
          { name: name, sha: sha, manifest: read_manifest(File.join(fdir, sha)) }
        end
      end
    end

    def index_exist?(name, sha) = File.file?(index_path(name, sha))

    def read_index(name, sha)
      path = index_path(name, sha)
      File.file?(path) ? File.read(path) : nil
    end

    private

    def index_path(name, sha) = File.join(@store, name.to_s, sha.to_s, "index.html")

    def read_manifest(dir)
      path = File.join(dir, "manifest.json")
      return {} unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      {}
    end
  end

  # In-cluster MinIO static tier over HTTP. Enumeration reads registry.json;
  # index.html is fetched per build. Anonymous GET is enough (the bucket is
  # download-public). Every network op degrades to nil/[]/false on failure so a
  # missing tier never raises into a request.
  class HttpBackend
    require "net/http"
    require "uri"

    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 5

    def initialize(base)
      @base = base.to_s.sub(%r{/+\z}, "")
    end

    def available? = true

    def entries
      body = http_get("#{@base}/registry.json")
      return [] unless body

      idx = JSON.parse(body)
      return [] unless idx.is_a?(Hash)

      (idx["families"] || {}).flat_map do |name, builds|
        Array(builds).map { |m| { name: name.to_s, sha: m["sha"].to_s, manifest: m } }
      end
    rescue JSON::ParserError
      []
    end

    def index_exist?(name, sha)
      http_head("#{@base}/#{name}/#{sha}/index.html")
    end

    def read_index(name, sha)
      http_get("#{@base}/#{name}/#{sha}/index.html")
    end

    private

    def http_get(url)
      resp = http_request(url, Net::HTTP::Get)
      resp.is_a?(Net::HTTPSuccess) ? resp.body : nil
    end

    def http_head(url)
      http_request(url, Net::HTTP::Head).is_a?(Net::HTTPSuccess)
    end

    def http_request(url, klass)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.request(klass.new(uri.request_uri))
    rescue StandardError
      nil
    end
  end
end
