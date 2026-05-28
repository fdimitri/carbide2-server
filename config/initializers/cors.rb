# Be sure to restart your server when you modify this file.
#
# Allowed origins come from CARBIDE_CORS_ORIGINS (comma-separated). Each entry
# can be a literal origin (https://carbide.example.com) or a regex wrapped in
# slashes (/^https?:\/\/.+\.internal$/). When unset, falls back to common local
# development hostnames.

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    raw = ENV["CARBIDE_CORS_ORIGINS"].to_s.strip
    parsed =
      if raw.empty?
        [/localhost:\d+/, /127\.0\.0\.1:\d+/, /192\.168\.\d+\.\d+:\d+/]
      else
        raw.split(",").map(&:strip).reject(&:empty?).map do |entry|
          if entry.start_with?("/") && entry.end_with?("/")
            Regexp.new(entry[1..-2])
          else
            entry
          end
        end
      end

    origins(*parsed)

    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      credentials: true
  end
end
