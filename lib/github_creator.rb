# frozen_string_literal: true

require 'uri'
require 'securerandom'

begin
  require 'octokit'
rescue LoadError
  # GitHub stays unavailable while local SCM providers continue to work.
end

class GithubCreator < ScmCreator
  class << self
    def configured?
      options.is_a?(Hash) && options['path'].present?
    end

    def enabled?
      configured? && defined?(Octokit::Client)
    end

    def api_token(repository = nil)
      repository&.password.presence || api['token'].presence
    end

    def local?
      false
    end

    def sanitize(attributes)
      return attributes unless attributes.key?('url')

      value = attributes['url'].to_s.strip
      unless github_url?(value)
        name = repository_name(value)
        owner = api['organization'].presence || 'user'
        value = "https://github.com/#{owner}/#{name}.git"
      end
      value += '.git' unless value.end_with?('.git')
      attributes.merge('url' => value)
    end

    def access_url(path, repository = nil)
      github_url?(path) ? path : repository&.url
    end

    def access_root_url(_path, _repository = nil)
      nil
    end

    def external_url(repository, _accepted_scheme = nil)
      repository.url
    end

    def default_path(identifier)
      identifier.to_s
    end

    def existing_path(_identifier, repository = nil)
      repository&.root_url if repository&.root_url.present? && File.directory?(repository.root_url)
    end

    def repository_name(value)
      value.to_s.sub(%r{/+\z}, '').split(/[\/:]/).last.to_s.delete_suffix('.git').presence
    end

    def repository_full_name(value)
      match = %r{\A(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+?)(?:\.git)?/?\z}i.match(value.to_s)
      match && match[1]
    end

    def repository_format
      'https://github.com/<owner>/<repository>.git'
    end

    # Remote existence is resolved in create_repository so the same repository-specific
    # credential and owner calculation are used for lookup and creation.
    def repository_exists?(_identifier)
      false
    end

    def create_repository(path, repository = nil)
      requested_full_name = repository_full_name(repository&.url)
      if api_token(repository).blank? && requested_full_name.present? && !requested_full_name.start_with?('user/')
        repository&.merge_extra_info(
          'extra_github_existing_repository' => '1',
          'extra_created_with_scm' => '1'
        )
        return repository.url
      end
      unless api_token(repository)
        repository&.errors&.add(:password, :blank)
        return false
      end

      github_client = client(repository)
      owner = api_owner(repository)
      name = repository_name(path)
      requested_full_name = nil if requested_full_name&.start_with?('user/')
      full_name = requested_full_name || "#{owner}/#{name}"

      response = existing_repository(github_client, full_name)
      if response.nil?
        if full_name.split('/').first.casecmp?(owner.to_s)
          response = github_client.create_repository(name, create_options)
        else
          repository&.errors&.add(:base, :github_repository_not_accessible, repository: full_name)
          return false
        end
      else
        repository&.merge_extra_info('extra_github_existing_repository' => '1')
      end

      use_ssh = options['clone_protocol'].to_s == 'ssh' && repository&.password.blank?
      clone_url = use_ssh ? response[:ssh_url] : response[:clone_url]
      return false if clone_url.blank?

      repository&.merge_extra_info('extra_created_with_scm' => '1')
      clone_url
    rescue Octokit::Error => e
      Rails.logger.error "SCM Creator GitHub repository creation failed: #{e.message}"
      repository&.errors&.add(:base, :github_api_request_failed, message: e.message)
      false
    end

    def can_register_hook?
      enabled? && api['register_hook'].to_s != 'forbid' && webhook_url_available?
    end

    def webhook_url_available?
      configured? && Setting.host_name.present?
    end

    def webhook_url(repository)
      root = Redmine::Utils.relative_url_root.to_s
      "#{Setting.protocol}://#{Setting.host_name}#{root}/scm/github/webhooks/#{repository.id}"
    end

    def register_hook(repository)
      return false unless can_register_hook?
      return false unless api_token(repository)

      full_name = repository_full_name(repository.url)
      return false if full_name.blank?

      config = {
        url: webhook_url(repository),
        content_type: 'json',
        insecure_ssl: '0',
        secret: repository.ensure_github_webhook_secret
      }
      hook_id = repository.extra_info&.fetch('extra_hook_id', nil).presence
      response = if hook_id
                   update_or_replace_hook(client(repository), full_name, hook_id, config)
                 else
                   client(repository).create_hook(full_name, 'web', config, events: ['push'], active: true)
                 end
      Rails.logger.info "SCM Creator registered GitHub push webhook for #{full_name}"
      response
    rescue Octokit::Error => e
      Rails.logger.error "SCM Creator GitHub webhook registration failed: #{e.message}"
      false
    end

    def api
      options.is_a?(Hash) && options['api'].is_a?(Hash) ? options['api'] : {}
    end

    def test_connection(url:, token: nil, repository: nil)
      token ||= api_token(repository)
      return {ok: false, message: I18n.t(:error_github_token_missing)} if token.blank?

      github_client = client_with_token(token)
      login = github_client.user[:login]
      full_name = repository_full_name(url)
      if full_name.present?
        remote = github_client.repository(full_name)
        return {
          ok: true,
          message: I18n.t(:notice_github_connection_repository_ok, account: login, repository: remote[:full_name])
        }
      end

      {ok: true, message: I18n.t(:notice_github_connection_ok, account: login)}
    rescue Octokit::NotFound
      {ok: false, message: I18n.t(:error_github_repository_not_accessible)}
    rescue Octokit::Error => e
      Rails.logger.warn "SCM Creator GitHub connection test failed: #{e.class.name}"
      {ok: false, message: I18n.t(:error_github_connection_failed, message: e.message)}
    end

    private

    def client(repository = nil)
      client_with_token(api_token(repository))
    end

    def client_with_token(token)
      client_options = {
        access_token: token,
        connection_options: {
          request: {
            open_timeout: positive_timeout(api['open_timeout'], 5),
            timeout: positive_timeout(api['timeout'], 15)
          }
        }
      }
      client_options[:api_endpoint] = api['endpoint'] if api['endpoint'].present?
      Octokit::Client.new(client_options)
    end

    def create_options
      configured = options['options'].is_a?(Hash) ? options['options'].deep_symbolize_keys : {}
      configured[:organization] ||= api['organization'] if api['organization'].present?
      configured
    end

    def api_owner(repository = nil)
      api['organization'].presence || client(repository).user[:login]
    end

    def existing_repository(github_client, full_name)
      github_client.repository(full_name)
    rescue Octokit::NotFound
      nil
    end

    def update_or_replace_hook(github_client, full_name, hook_id, config)
      github_client.edit_hook(full_name, hook_id.to_i, 'web', config, events: ['push'], active: true)
    rescue Octokit::NotFound
      github_client.create_hook(full_name, 'web', config, events: ['push'], active: true)
    end

    def positive_timeout(value, fallback)
      value.to_i.positive? ? value.to_i : fallback
    end

    def github_url?(value)
      repository_full_name(value).present?
    end
  end
end
