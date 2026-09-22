# frozen_string_literal: true

require 'fileutils'
require 'shellwords'

class ScmCreator
  include Redmine::I18n

  class << self
    def interface(repository)
      type = if repository.is_a?(Repository)
               repository.class.name
             elsif repository.is_a?(Class)
               repository.name
             else
               repository.to_s
             end
      "#{type.demodulize}Creator".constantize
    rescue NameError
      nil
    end

    def scm_id
      name.delete_suffix('Creator').downcase if name.end_with?('Creator')
    end

    def enabled?
      false
    end

    def local?
      true
    end

    def options
      ScmConfig[scm_id]
    end

    def sanitize(attributes)
      attributes
    end

    def access_url(path, repository = nil)
      suffix = options && options['append'].presence
      return access_root_url(path, repository) unless suffix

      File.join(access_root_url(path, repository), suffix)
    end

    def access_root_url(path, _repository = nil)
      path
    end

    def path(identifier)
      File.join(options.fetch('path'), identifier.to_s)
    end

    def external_url(repository, accepted_scheme = %r{\Ahttps?://})
      base_url = options && options['url'].to_s.sub(%r{/+\z}, '')
      name = repository_name(repository.root_url)
      return if base_url.blank? || name.blank?

      if base_url.match?(accepted_scheme)
        "#{base_url}/#{name}"
      else
        "#{Setting.protocol}://#{Setting.host_name}/#{base_url.sub(%r{\A/+}, '')}/#{name}"
      end
    end

    def default_path(identifier)
      path(identifier)
    end

    def existing_path(identifier, _repository = nil)
      candidate = default_path(identifier)
      candidate if File.directory?(candidate)
    end

    def repository_name(repository_path)
      return if repository_path.blank? || options.blank? || options['path'].blank?

      base = normalized_path(options['path'])
      match = %r{\A#{Regexp.escape(base)}/([^/]+)/?\z}.match(normalized_path(repository_path))
      match && match[1]
    end

    def belongs_to_project?(name, identifier)
      name.to_s.match?(%r{\A#{Regexp.escape(identifier.to_s)}(?:\..+)?\z})
    end

    def repository_format
      "#{normalized_path(options.fetch('path'))}/<#{l(:label_repository_format)}>/"
    end

    def repository_exists?(identifier)
      File.directory?(default_path(identifier))
    end

    def create_repository(_path, _repository = nil)
      false
    end

    def delete_repository(repository_path)
      return false unless managed_path?(repository_path)

      FileUtils.remove_entry(repository_path)
      true
    rescue StandardError => e
      Rails.logger.error "SCM Creator failed to delete #{repository_path}: #{e.message}"
      false
    end

    def execute(script, repository_path, project)
      return if script.blank?
      unless File.file?(script) && File.executable?(script)
        Rails.logger.warn "SCM Creator cannot execute lifecycle script: #{script}"
        return
      end

      environment = project.custom_field_values.each_with_object({}) do |custom_value, values|
        key = custom_value.custom_field.name.gsub(/[^a-z0-9]+/i, '_').upcase
        values["SCM_CUSTOM_FIELD_#{key}"] = custom_value.value.to_s if key.present?
      end
      system(environment, script, repository_path.to_s, scm_id.to_s, project.identifier.to_s)
    end

    def init_repository(_repository); end

    private

    def append_options(arguments)
      configured = options && options['options']
      arguments.concat(configured.is_a?(Array) ? configured.map(&:to_s) : Shellwords.split(configured.to_s)) if configured.present?
    end

    def normalized_path(value)
      value.to_s.tr('\\', '/').sub(%r{/+\z}, '')
    end

    def managed_path?(repository_path)
      return false if repository_path.blank? || options.blank? || options['path'].blank?

      base = File.expand_path(options['path'])
      candidate = File.expand_path(repository_path)
      File.dirname(candidate) == base && candidate != base
    end
  end
end
