# frozen_string_literal: true

# The workspace server verifies control-minted RS256 tokens against the JWKS
# public keys (ADR-015). It shares the verifier with the worker (same image,
# worker/ is copied into /app/worker at build time).
require Rails.root.join('worker', 'jwt_verifier.rb')

JwtVerifier.configure(
  jwks_url: ENV.fetch('CONTROL_JWKS_URL') {
    'http://control-plane.carbide-system.svc.cluster.local:3001/.well-known/jwks.json'
  }
)
