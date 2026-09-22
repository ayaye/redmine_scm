# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tempfile'

class GithubMirrorManager
  attr_reader :path, :root

  def initialize(path, root: GithubCreator.options && GithubCreator.options['path'])
    @path = File.expand_path(path.to_s)
    @root = File.expand_path(root.to_s)
  end

  def prepare
    return failure(:scm_github_mirror_path_invalid) unless managed_path?

    FileUtils.mkdir_p(root)
    return failure(:scm_github_mirror_root_not_writable) unless writable_root?
    return failure(:scm_github_mirror_disk_space_low, minimum: minimum_free_space_mb) unless enough_disk_space?
    return success(:existing) if valid_mirror?
    return failure(:scm_github_mirror_path_occupied) if File.exist?(path)

    success(:new)
  rescue StandardError => e
    Rails.logger.error "SCM Creator GitHub mirror preflight failed: #{e.message}"
    failure(:scm_github_mirror_preflight_failed)
  end

  def valid_mirror?
    return false unless File.directory?(path)

    _output, _error, status = Open3.capture3(git_command, '--git-dir', path, 'rev-parse', '--is-bare-repository')
    status.success?
  rescue StandardError
    false
  end

  def cleanup_failed_clone
    return unless managed_path? && File.exist?(path) && !valid_mirror?

    FileUtils.remove_entry_secure(path)
  rescue StandardError => e
    Rails.logger.error "SCM Creator could not clean failed GitHub mirror #{path}: #{e.message}"
  end

  def size_bytes
    return unless File.directory?(path)

    output, _error, status = Open3.capture3('du', '-sk', path)
    return unless status.success?

    output.to_s.split.first.to_i * 1024
  rescue StandardError => e
    Rails.logger.warn "SCM Creator could not determine GitHub mirror size: #{e.message}"
    nil
  end

  def available_bytes
    output, _error, status = Open3.capture3('df', '-Pk', root)
    return unless status.success?

    line = output.lines.reject(&:blank?).last
    fields = line.to_s.split
    fields[-3].to_i * 1024 if fields.length >= 4
  rescue StandardError => e
    Rails.logger.warn "SCM Creator could not determine free GitHub mirror disk space: #{e.message}"
    nil
  end

  private

  def managed_path?
    path != root && File.dirname(path) == root && !File.symlink?(path)
  end

  def writable_root?
    Tempfile.create('.redmine-scm-write-check', root) { true }
  rescue SystemCallError
    false
  end

  def enough_disk_space?
    minimum = minimum_free_space_mb
    return true unless minimum.positive?

    available = available_bytes
    if available.nil?
      Rails.logger.warn 'SCM Creator could not determine free disk space for the GitHub mirror root'
      return true
    end
    available >= minimum.megabytes
  end

  def minimum_free_space_mb
    GithubCreator.options.to_h['minimum_free_space_mb'].to_i
  end

  def git_command
    Redmine::Scm::Adapters::GitAdapter.client_command
  end

  def success(state)
    {ok: true, state: state}
  end

  def failure(error, options = {})
    {ok: false, error: error, options: options}
  end
end
