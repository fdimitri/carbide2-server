# Public splash served at /. Front door for the cluster.
# GET /about redirects to the SPA's /about page (which has the full Tailwind
# design system); ?format=json returns acronym data for AboutPage.vue to fetch.
class LandingController < ActionController::Base
  layout 'landing'

  WORKSPACE_PATH = '/w/1'.freeze

  ACRONYMS = begin
    YAML.load_file(Rails.root.join('config', 'carbide_acronyms.yml'))
        .fetch('acronyms', [])
  rescue => e
    Rails.logger.warn("[LandingController] could not load acronyms: #{e.message}")
    ['Collaborative Artificial Resource Builder Interface Development Ecosystem']
  end.freeze

  def index
    @acronym = ACRONYMS.sample
  end

  # GET /about — redirect browsers to the SPA; serve JSON to AboutPage.vue.
  def about
    respond_to do |fmt|
      fmt.json { render json: { acronym: ACRONYMS.sample, all: ACRONYMS } }
      fmt.any  { redirect_to "#{WORKSPACE_PATH}/about", allow_other_host: false }
    end
  end
end
