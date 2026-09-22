# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'net/http'
require 'openssl'
require 'time'
require 'uri'

module VcsadminGit
  class Error < StandardError
    attr_reader :code, :http_status, :request_id

    def initialize(message = nil, code: nil, http_status: nil, request_id: nil)
      super(message.to_s.truncate(300))
      @code = code
      @http_status = http_status
      @request_id = request_id
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  class AuthorizationError < Error; end
  class NotFoundError < Error; end
  class InvalidRequestError < Error; end
  class InvalidRevisionError < Error; end
  class InvalidPathError < Error; end
  class ResponseTooLargeError < Error; end
  class RateLimitError < Error; end
  class TemporaryServiceError < Error; end
  class NetworkError < Error; end
  class DnsError < NetworkError; end
  class ConnectionRefusedError < NetworkError; end
  class ConnectTimeoutError < NetworkError; end
  class ReadTimeoutError < NetworkError; end
  class TlsError < NetworkError; end
  class InvalidResponseError < Error; end
  class IncompatibleApiError < Error; end
  class MissingCapabilityError < Error; end
  class ContentUnavailableError < Error
    attr_reader :reason

    def initialize(reason)
      @reason = reason.to_s
      super(@reason, code: @reason)
    end
  end
  class TruncatedDiffError < Error; end

  class Client
    API_VERSION = 'v1'
    REQUIRED_CAPABILITIES = %w[
      repositories branches tags commits commit_details unified_diff tree text_blob path_history
    ].freeze
    TEMPORARY_STATUSES = [429, 500, 502, 503, 504].freeze

    attr_reader :configuration

    def initialize(username:, password:, configuration: Configuration.current)
      @username = username.to_s
      @password = password.to_s
      @configuration = configuration
      @memo = {}
      raise ConfigurationError, 'VCSAdmin username is missing' if @username.blank?
      raise ConfigurationError, 'VCSAdmin password is missing' if @password.blank?
    rescue ArgumentError => e
      raise ConfigurationError, e.message
    end

    def verify!
      data = status
      raise IncompatibleApiError, 'Unsupported VCSAdmin API version' unless data['api_version'] == API_VERSION
      unless data['available'] == true && Array(data['repository_types']).include?('git') && data['read_only'] == true
        raise IncompatibleApiError, 'VCSAdmin Git read-only API is unavailable'
      end
      missing = REQUIRED_CAPABILITIES - Array(data['capabilities'])
      raise MissingCapabilityError, missing.join(', ') if missing.any?

      data
    end

    def status
      memoize(:status) do
        if configuration.cache_duration.positive?
          key = "redmine_scm/vcsadmin_git/status/#{Digest::SHA256.hexdigest(configuration.base_url)}"
          Rails.cache.fetch(key, expires_in: configuration.cache_duration) { get('status') }
        else
          get('status')
        end
      end
    end

    def repositories
      required_array(get('repositories'), 'repositories').each {|item| validate_repository(item)}
    end

    def repository(repository_id)
      validate_repository(
        required_object(get("repositories/#{repository_identifier(repository_id)}"), 'repository'),
        details: true
      )
    end

    def branches(repository_id)
      required_array(get("repositories/#{repository_identifier(repository_id)}/branches"), 'branches').each do |item|
        invalid_response!('branch') unless item['name'].is_a?(String) &&
                                           valid_commit_id?(item['commit_id']) &&
                                           (item['latest_commit_date'].nil? ||
                                             item['latest_commit_date'].is_a?(String)) &&
                                           [true, false].include?(item['default'])
      end
    end

    def tags(repository_id)
      required_array(get("repositories/#{repository_identifier(repository_id)}/tags"), 'tags').each do |item|
        invalid_response!('tag') unless item['name'].is_a?(String) &&
                                        valid_commit_id?(item['commit_id']) &&
                                        (item['date'].nil? || item['date'].is_a?(String)) &&
                                        (item['tagger'].nil? || item['tagger'].is_a?(String)) &&
                                        [true, false].include?(item['annotated'])
      end
    end

    def commits(repository_id, revision: 'HEAD', path: nil, limit: nil, cursor: nil)
      parameters = {revision: revision, limit: limit || configuration.page_size}
      parameters[:path] = path if path.present?
      parameters[:cursor] = cursor if cursor.present?
      validate_page(get("repositories/#{repository_identifier(repository_id)}/commits", parameters), 'commits')
    end

    def commit(repository_id, commit_id)
      required_object(
        get("repositories/#{repository_identifier(repository_id)}/commits/#{revision_identifier(commit_id)}"),
        'commit'
      )
    end

    def diff(repository_id, commit_id)
      value = required_object(
        get("repositories/#{repository_identifier(repository_id)}/commits/#{revision_identifier(commit_id)}/diff"),
        'diff'
      )
      unless value['format'] == 'unified' && value['diff'].is_a?(String) &&
             [true, false].include?(value['truncated']) &&
             [true, false].include?(value['binary_files_omitted']) &&
             value['limit_bytes'].is_a?(Integer)
        invalid_response!('diff')
      end
      value
    end

    def tree(repository_id, revision: 'HEAD', path: '')
      required_object(get(
        "repositories/#{repository_identifier(repository_id)}/tree",
        revision: revision, path: normalize_path(path, allow_empty: true)
      ), 'tree')
    end

    def blob(repository_id, revision: 'HEAD', path:)
      required_object(get(
        "repositories/#{repository_identifier(repository_id)}/blob",
        revision: revision, path: normalize_path(path)
      ), 'blob')
    end

    def history(repository_id, revision: 'HEAD', path:, limit: nil, cursor: nil, follow_renames: false)
      parameters = {
        revision: revision,
        path: normalize_path(path),
        limit: limit || configuration.page_size,
        follow_renames: follow_renames ? '1' : '0'
      }
      parameters[:cursor] = cursor if cursor.present?
      validate_page(
        get("repositories/#{repository_identifier(repository_id)}/history", parameters),
        'history'
      )
    end

    def normalize_path(path, allow_empty: false)
      raw = path.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
      if raw.start_with?('/', '\\') || raw.match?(/\A[A-Za-z]:/)
        raise InvalidPathError.new('Invalid repository path', code: 'invalid_path')
      end
      value = raw.tr('\\', '/').sub(%r{/+\z}, '')
      return '' if allow_empty && value.empty?
      if value.empty? || value.include?("\0") || value.bytesize > 4096 ||
         value.split('/').any? {|segment| segment.blank? || %w[. ..].include?(segment)}
        raise InvalidPathError.new('Invalid repository path', code: 'invalid_path')
      end

      value
    end

    private

    def get(path, parameters = {})
      uri = configuration.base_uri.dup
      uri.path = "#{configuration.base_uri.path}/#{path}"
      query = parameters.compact.transform_values(&:to_s)
      uri.query = URI.encode_www_form(query) if query.any?
      attempts = 0

      begin
        attempts += 1
        response, body = perform_request(uri)
        status = response.code.to_i
        if TEMPORARY_STATUSES.include?(status) && attempts <= configuration.retry_count
          wait = retry_delay(response, attempts)
          sleep(wait) if wait.positive?
          raise RetryRequest
        end
        parse_response(response, body)
      rescue RetryRequest
        retry
      end
    end

    def perform_request(uri)
      request = Net::HTTP::Get.new(uri.request_uri)
      request['Accept'] = 'application/json'
      request['User-Agent'] = "Redmine-SCM-Creator/#{Redmine::Plugin.find(:redmine_scm).version} VCSAdmin-Git"
      request.basic_auth(@username, @password)
      body = +''
      response = nil

      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == 'https',
        open_timeout: configuration.open_timeout,
        read_timeout: configuration.read_timeout,
        verify_mode: configuration.verify_tls? ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      ) do |http|
        http.request(request) do |current_response|
          response = current_response
          current_response.read_body do |chunk|
            body << chunk
            if body.bytesize > configuration.max_response_bytes
              raise ResponseTooLargeError, 'VCSAdmin response exceeds the local size limit'
            end
          end
        end
      end
      [response, body]
    rescue Net::OpenTimeout
      raise ConnectTimeoutError, 'VCSAdmin connection timed out'
    rescue Net::ReadTimeout
      raise ReadTimeoutError, 'VCSAdmin response timed out'
    rescue SocketError
      raise DnsError, 'VCSAdmin host could not be resolved'
    rescue Errno::ECONNREFUSED
      raise ConnectionRefusedError, 'VCSAdmin refused the connection'
    rescue OpenSSL::SSL::SSLError
      raise TlsError, 'VCSAdmin TLS certificate validation failed'
    rescue IOError, SystemCallError => e
      raise NetworkError, e.class.name
    end

    def parse_response(response, body)
      status = response.code.to_i
      if status.between?(300, 399)
        raise InvalidResponseError.new('VCSAdmin redirect was refused', http_status: status)
      end
      content_type = response['Content-Type'].to_s.downcase
      unless content_type.start_with?('application/json')
        raise InvalidResponseError.new('VCSAdmin returned a non-JSON response', http_status: status)
      end
      payload = JSON.parse(body)
      unless payload.is_a?(Hash)
        raise InvalidResponseError.new('VCSAdmin returned an invalid response envelope', http_status: status)
      end
      if status.between?(200, 299)
        data = payload['data']
        raise InvalidResponseError, 'VCSAdmin response has no data object' unless data.is_a?(Hash)

        return data
      end

      error = payload['error']
      unless error.is_a?(Hash) && error['code'].present?
        raise InvalidResponseError.new('VCSAdmin returned an invalid error envelope', http_status: status)
      end
      raise mapped_error(error['code'], error['message'], status, error['request_id'] || response['X-Request-ID'])
    rescue JSON::ParserError
      raise InvalidResponseError.new('VCSAdmin returned malformed JSON', http_status: response.code.to_i)
    end

    def mapped_error(code, _remote_message, status, request_id)
      klass =
        case code
        when 'authentication_required', 'invalid_credentials' then AuthenticationError
        when 'repository_not_found', 'repository_path_not_found', 'commit_not_found' then NotFoundError
        when 'invalid_revision', 'git_request_invalid' then InvalidRevisionError
        when 'invalid_path', 'not_a_file' then InvalidPathError
        when 'invalid_parameter', 'invalid_limit', 'invalid_cursor', 'path_required', 'https_required' then InvalidRequestError
        when 'tree_too_large', 'repositories_too_large', 'refs_too_large', 'commit_too_large',
             'git_output_too_large', 'diff_too_large', 'response_too_large' then ResponseTooLargeError
        when 'api_disabled', 'git_unavailable', 'git_timeout', 'internal_error' then TemporaryServiceError
        else
          status == 429 ? RateLimitError : InvalidResponseError
        end
      klass.new("VCSAdmin request failed (#{code})", code: code, http_status: status, request_id: request_id)
    end

    def repository_identifier(value)
      string = value.to_s
      raise ConfigurationError, 'Invalid VCSAdmin repository ID' unless string.match?(/\A[1-9][0-9]*\z/)

      string
    end

    def revision_identifier(value)
      string = value.to_s
      unless string.match?(/\A[0-9A-Za-z._-]{1,255}\z/) && !string.start_with?('-')
        raise InvalidRevisionError, 'Invalid VCSAdmin revision'
      end

      string
    end

    def retry_delay(response, attempt)
      retry_after = response['Retry-After'].to_s
      seconds =
        if retry_after.match?(/\A\d+\z/)
          retry_after.to_i
        elsif retry_after.present?
          [(Time.httpdate(retry_after) - Time.now).ceil, 0].max
        end
      [seconds || (0.1 * attempt), configuration.max_retry_after].min
    rescue ArgumentError
      [0.1 * attempt, configuration.max_retry_after].min
    end

    def required_object(data, key)
      value = data[key]
      raise InvalidResponseError, "VCSAdmin response has no #{key} object" unless value.is_a?(Hash)

      value
    end

    def validate_repository(item, details: false)
      valid = item['id'].to_s.match?(/\A[1-9][0-9]*\z/) &&
              item['name'].is_a?(String) &&
              item['type'] == 'git' &&
              (item['default_branch'].nil? || item['default_branch'].is_a?(String)) &&
              (item['head_commit_id'].nil? || valid_commit_id?(item['head_commit_id']))
      if details
        valid &&= item['capabilities'].is_a?(Array) && item['read_only'] == true
      end
      invalid_response!('repository') unless valid

      item
    end

    def valid_commit_id?(value)
      value.to_s.match?(/\A[0-9a-f]{40,64}\z/)
    end

    def invalid_response!(resource)
      raise InvalidResponseError, "VCSAdmin returned invalid #{resource} data"
    end

    def required_array(data, key)
      value = data[key]
      unless value.is_a?(Array) && value.all? {|item| item.is_a?(Hash)}
        raise InvalidResponseError, "VCSAdmin response has no valid #{key} array"
      end

      value
    end

    def validate_page(data, collection_key)
      required_array(data, collection_key)
      pagination = required_object(data, 'pagination')
      unless pagination['limit'].is_a?(Integer) &&
             (pagination['next_cursor'].nil? || pagination['next_cursor'].is_a?(String)) &&
             [true, false].include?(pagination['truncated'])
        raise InvalidResponseError, 'VCSAdmin response has invalid pagination metadata'
      end
      data
    end

    def memoize(key)
      return @memo[key] if @memo.key?(key)

      @memo[key] = yield
    end

    class RetryRequest < StandardError; end
  end
end
