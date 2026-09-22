# frozen_string_literal: true

require 'openssl'

class ScmGithubWebhooksController < ApplicationController
  skip_before_action :check_if_login_required
  skip_before_action :verify_authenticity_token

  def create
    repository = Repository::Github.find_by(id: params[:repository_id])
    return head :not_found unless repository
    return head :unauthorized unless valid_signature?(repository)
    return head :accepted unless request.headers['X-GitHub-Event'].to_s == 'push'

    head(repository.fetch_changesets ? :accepted : :service_unavailable)
  rescue StandardError => e
    Rails.logger.error "SCM Creator GitHub webhook processing failed: #{e.message}"
    head :internal_server_error
  end

  private

  def valid_signature?(repository)
    secret = repository.github_webhook_secret
    signature = request.headers['X-Hub-Signature-256'].to_s
    return false if secret.blank? || !signature.start_with?('sha256=')

    expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, request.raw_post)}"
    ActiveSupport::SecurityUtils.secure_compare(signature, expected)
  end
end
