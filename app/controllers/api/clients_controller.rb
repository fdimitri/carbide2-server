# Lists the SPA client builds available to this workspace pod so the client's
# picker can offer a choice. Selecting one is a client concern: it reloads with
# `?client=<family>@<sha>`, which SpaController resolves and pins.
class Api::ClientsController < Api::BaseController
  def index
    reg = ClientRegistry.new
    families = reg.families.map do |name|
      { name:, default_sha: reg.newest(name)&.sha, builds: reg.builds(name).map(&:as_json_h) }
    end
    render json: { default: reg.default_family, families: }
  end
end
