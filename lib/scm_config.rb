# frozen_string_literal: true

require 'erb'
require 'yaml'

class ScmConfig
  class << self
    def [](key)
      settings[key.to_s]
    end

    def configured?
      settings.any?
    end

    def reload!
      @settings = nil
    end

    private

    def settings
      @settings ||= load_settings
    end

    def load_settings
      path = Rails.root.join('config', 'scm.yml')
      unless path.file?
        Rails.logger.warn "SCM Creator configuration not found: #{path}"
        return {}
      end

      document = ERB.new(path.read).result
      config = YAML.safe_load(document, aliases: false) || {}
      environment = config[Rails.env]
      return environment.deep_stringify_keys if environment.is_a?(Hash)

      Rails.logger.warn "SCM Creator configuration has no #{Rails.env} section: #{path}"
      {}
    rescue Psych::Exception => e
      Rails.logger.error "SCM Creator configuration is invalid: #{e.message}"
      {}
    end
  end
end
