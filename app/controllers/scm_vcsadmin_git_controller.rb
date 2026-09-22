# frozen_string_literal: true

class ScmVcsadminGitController < ApplicationController
  before_action :require_login
  before_action :find_project
  before_action :authorize_manage_repository
  before_action :find_repository, only: :synchronize

  def test_connection
    repository = find_optional_repository
    base_url = params[:vcsadmin_base_url].to_s.presence || repository&.url
    username = params[:vcsadmin_username].to_s.presence || repository&.login
    password = submitted_password.presence || repository&.password
    base_url, repository_id_from_url = VcsadminGit::Configuration.split_repository_url(base_url)
    repository_id_from_url ||= repository&.vcsadmin_repository_id
    if repository_id_from_url.blank?
      raise VcsadminGit::ConfigurationError.new(
        'A VCSAdmin repository URL is required',
        code: 'repository_url_required'
      )
    end
    configuration = VcsadminGit::Configuration.current(base_url)
    client = VcsadminGit::Client.new(
      username: username,
      password: password,
      configuration: configuration
    )
    status = client.verify!
    details = client.repository(repository_id_from_url)
    missing = VcsadminGit::Client::REQUIRED_CAPABILITIES - Array(details['capabilities'])
    raise VcsadminGit::MissingCapabilityError, missing.join(', ') if missing.any?

    render json: {
      message: l(:notice_vcsadmin_repository_connection_ok, repository: details['name']),
      repository: repository_json(details),
      api_version: status['api_version'],
      limits: status['limits']
    }
  rescue ArgumentError
    render json: {message: l(:error_vcsadmin_configuration), code: 'invalid_configuration'},
           status: :unprocessable_entity
  rescue VcsadminGit::Error => e
    log_connection_error(e)
    render json: {message: localized_api_error(e), code: e.code, request_id: e.request_id},
           status: response_status(e)
  end

  def synchronize
    if @repository.fetch_changesets
      flash[:notice] = l(:notice_vcsadmin_sync_batch_complete)
    else
      flash[:error] = @repository.vcsadmin_last_error.presence || l(:error_vcsadmin_sync_failed)
    end
    redirect_to edit_repository_path(@repository)
  end

  private

  def find_project
    @project = Project.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_manage_repository
    deny_access unless User.current.allowed_to?(:manage_repository, @project)
  end

  def find_repository
    @repository = @project.repositories.find(params[:repository_id])
    render_404 unless @repository.is_a?(Repository::VcsadminGit)
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_optional_repository
    return if params[:repository_id].blank?

    repository = @project.repositories.find_by(id: params[:repository_id])
    repository if repository.is_a?(Repository::VcsadminGit)
  end

  def submitted_password
    value = params[:vcsadmin_password].to_s
    value unless value.blank? || value.match?(/\Ax{15}\z/)
  end

  def repository_json(item)
    {
      id: item['id'].to_s,
      name: item['name'].to_s,
      description: item['description'].to_s,
      type: item['type'].to_s,
      default_branch: item['default_branch'].to_s
    }
  end

  def localized_api_error(error)
    key =
      case error
      when VcsadminGit::ConfigurationError then :error_vcsadmin_configuration
      when VcsadminGit::AuthenticationError then :error_vcsadmin_authentication
      when VcsadminGit::TlsError then :error_vcsadmin_tls
      when VcsadminGit::DnsError then :error_vcsadmin_dns
      when VcsadminGit::ConnectionRefusedError then :error_vcsadmin_connection_refused
      when VcsadminGit::ConnectTimeoutError then :error_vcsadmin_connect_timeout
      when VcsadminGit::ReadTimeoutError then :error_vcsadmin_read_timeout
      when VcsadminGit::IncompatibleApiError then :error_vcsadmin_api_version
      when VcsadminGit::MissingCapabilityError then :error_vcsadmin_capability
      when VcsadminGit::NotFoundError then :error_vcsadmin_repository_not_accessible
      when VcsadminGit::ResponseTooLargeError then :error_vcsadmin_response_too_large
      when VcsadminGit::RateLimitError then :error_vcsadmin_rate_limit
      when VcsadminGit::TemporaryServiceError then :error_vcsadmin_service_unavailable
      when VcsadminGit::InvalidResponseError then :error_vcsadmin_invalid_response
      else :error_vcsadmin_connection
      end
    l(key)
  end

  def response_status(error)
    case error
    when VcsadminGit::AuthenticationError then :unauthorized
    when VcsadminGit::NotFoundError then :not_found
    when VcsadminGit::RateLimitError then :too_many_requests
    when VcsadminGit::TemporaryServiceError then :service_unavailable
    else :unprocessable_entity
    end
  end

  def log_connection_error(error)
    Rails.logger.warn(
      "VCSAdmin Git connection test failed project=#{@project.id} status=#{error.http_status} " \
      "code=#{error.code} request_id=#{error.request_id}"
    )
  end
end
