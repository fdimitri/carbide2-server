# Registry of built SPA clients available to this workspace pod.
#
# The Decider serves clients from a content-addressed store laid out as
#   <store>/<family>/<sha>/{index.html, manifest.json, assets/*}
# where <family> is a client name (e.g. "carbide2-client", "carbide2-mobile")
# and <sha> is the build's content address. Each build is compiled with an
# absolute Vite base of "/clients/<family>/<sha>/", so its asset URLs are
# already absolute and resolve to the static tier regardless of which
# workspace the shell is served from. This registry only has to (a) enumerate
# the available builds and (b) resolve a pinned build so SpaController can read
# and serve its index.html.
#
# The default backend is the local filesystem (dev-native and tests: the store
# lives under public/clients so ActionDispatch::Static serves the assets on the
# same origin). In production the same URL contract "/clients/<family>/<sha>/"
# is served by a dedicated MinIO-backed static tier via Traefik; a future HTTP
# backend can be slotted in behind the same public interface.
class ClientRegistry
  # A single resolved build. `dir` is the on-disk directory backing it.
  Build = Struct.new(:name, :sha, :dir, :manifest, keyword_init: true) do
    # Absolute, origin-relative base under which this build's assets live.
    def public_base = "/clients/#{name}/#{sha}/"
    def index_path  = File.join(dir, "index.html")
    def index_exist? = File.file?(index_path)
    def read_index   = File.read(index_path)
    def label        = manifest["label"].presence || sha
    def build_time   = manifest["build_time"]
    def floors       = manifest["floors"] || {}

    def as_json_h
      { name:, sha:, label:, build_time:, base: public_base, floors: }
    end
  end

  DEFAULT_FAMILY = "carbide2-client"

  def initialize(store: nil, default_family: nil)
    @store = (store || ENV["CARBIDE_CLIENT_STORE"].presence ||
              Rails.root.join("public", "clients").to_s)
    @default_family = default_family || ENV["CARBIDE_CLIENT_DEFAULT"].presence
  end

  def store_present? = File.directory?(@store)

  # Client family names present in the store (sorted).
  def families
    return [] unless store_present?

    Dir.children(@store).select { |c| File.directory?(File.join(@store, c)) }.sort
  end

  # Builds for a family, newest first (by manifest build_time, then dir mtime).
  def builds(name)
    dir = File.join(@store, name.to_s)
    return [] unless File.directory?(dir)

    Dir.children(dir).filter_map { |sha| build_for(name, sha) }
       .sort_by { |b| [b.build_time.to_s, File.mtime(b.dir).to_f] }
       .reverse
  end

  def all_builds = families.flat_map { |f| builds(f) }

  def build_for(name, sha)
    bdir = File.join(@store, name.to_s, sha.to_s)
    return nil unless File.directory?(bdir)

    Build.new(name: name.to_s, sha: sha.to_s, dir: bdir, manifest: read_manifest(bdir))
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

  private

  def read_manifest(bdir)
    path = File.join(bdir, "manifest.json")
    return {} unless File.file?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError
    {}
  end
end
