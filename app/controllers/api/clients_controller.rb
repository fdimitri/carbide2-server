# Lists the SPA client builds available to this workspace pod so the client's
# picker can offer a choice. Selecting one is a client concern: it reloads with
# `?client=<family>@<sha>`, which SpaController resolves and pins.
#
# Scoped to THIS pod's own family: a workspace pod can only serve its own
# family (the loader rejects cross-family cookie pins and 404s a cross-family
# ?client=), so listing another family here would just offer builds that fail.
class Api::ClientsController < Api::BaseController
  def index
    reg = ClientRegistry.new
    fam = reg.default_family
    builds = reg.builds(fam).map(&:as_json_h)
    families = fam ? [{ name: fam, default_sha: reg.newest(fam)&.sha, builds: }] : []
    render json: { default: fam, families: }
  end
end
