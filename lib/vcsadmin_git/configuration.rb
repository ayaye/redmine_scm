# frozen_string_literal: true

require 'uri'

module VcsadminGit
  class Configuration
    DEFAULTS = {
      'open_timeout' => 5,
      'read_timeout' => 20,
      'page_size' => 25,
      'sync_batch_size' => 25,
      'initial_import_batch_size' => 50,
      'max_pages_per_sync' => 3,
      'max_response_bytes' => 6 * 1024 * 1024,
      'max_file_bytes' => 1024 * 1024,
      'retry_count' => 1,
      'max_retry_after' => 2,
      'verify_tls' => true,
      'allow_http_development' => false,
      'cache_duration' => 0
    }.freeze

    attr_reader :base_uri

    class << self
      def split_repository_url(value)
        original = value.to_s.strip
        uri = URI.parse(original)
        return [original, nil] if uri.query || uri.fragment

        path = uri.path.to_s.sub(%r{/+\z}, '')
        match = path.match(%r{\A(?<base_path>.*?/api/v1/scm)/repositories/(?<repository_id>[1-9][0-9]*)\z})
        return [original, nil] unless match

        uri.path = match[:base_path]
        [uri.to_s, match[:repository_id]]
      rescue URI::InvalidURIError
        [original, nil]
      end

      def current(base_url = nil)
        values = ScmConfig['vcsadmin_git']
        values = values.is_a?(Hash) ? values.stringify_keys : {}
        values = values.merge('base_url' => base_url) unless base_url.nil?
        new(values)
      end

      def configured?(base_url = nil)
        current(base_url).valid?
      rescue StandardError
        false
      end
    end

    def initialize(values)
      @values = DEFAULTS.merge(values.is_a?(Hash) ? values.stringify_keys : {})
      @base_uri = normalize_base_url(@values['base_url'])
    end

    def valid?
      base_uri.present?
    end

    def base_url
      base_uri.to_s
    end

    def open_timeout
      positive_integer('open_timeout')
    end

    def read_timeout
      positive_integer('read_timeout')
    end

    def page_size
      positive_integer('page_size')
    end

    def sync_batch_size
      positive_integer('sync_batch_size')
    end

    def initial_import_batch_size
      positive_integer('initial_import_batch_size')
    end

    def max_pages_per_sync
      positive_integer('max_pages_per_sync')
    end

    def max_response_bytes
      positive_integer('max_response_bytes')
    end

    def max_file_bytes
      positive_integer('max_file_bytes')
    end

    def retry_count
      [[@values['retry_count'].to_i, 0].max, 2].min
    end

    def max_retry_after
      [[@values['max_retry_after'].to_i, 0].max, 5].min
    end

    def cache_duration
      [@values['cache_duration'].to_i, 0].max
    end

    def verify_tls?
      boolean('verify_tls')
    end

    private

    def normalize_base_url(value)
      raise ArgumentError, 'VCSAdmin base URL is not configured' if value.blank?

      uri = URI.parse(value.to_s.strip)
      unless %w[http https].include?(uri.scheme) && uri.host.present?
        raise ArgumentError, 'VCSAdmin base URL must be an absolute HTTP(S) URL'
      end
      raise ArgumentError, 'VCSAdmin base URL must not contain credentials' if uri.userinfo.present?
      raise ArgumentError, 'VCSAdmin base URL must not contain a query or fragment' if uri.query || uri.fragment
      if uri.scheme == 'http' && !(Rails.env.development? && boolean('allow_http_development'))
        raise ArgumentError, 'VCSAdmin requires HTTPS'
      end
      if !verify_tls? && !Rails.env.development?
        raise ArgumentError, 'TLS certificate verification can only be disabled in development'
      end

      path = uri.path.to_s.sub(%r{/+\z}, '')
      unless path.end_with?('/api/v1/scm')
        raise ArgumentError, 'VCSAdmin base URL must end with /api/v1/scm'
      end
      uri.path = path
      uri
    rescue URI::InvalidURIError
      raise ArgumentError, 'Invalid VCSAdmin base URL'
    end

    def positive_integer(key)
      value = @values[key].to_i
      raise ArgumentError, "#{key} must be a positive integer" unless value.positive?

      value
    end

    def boolean(key)
      ActiveModel::Type::Boolean.new.cast(@values[key])
    end
  end
end
