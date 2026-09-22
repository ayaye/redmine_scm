# frozen_string_literal: true

require_dependency 'repository/git'
require_relative '../../../lib/redmine/scm/adapters/github_adapter'
require_relative '../../../lib/github_mirror_manager'
require 'securerandom'

class Repository::Github < Repository::Git
  validates :url,
            format: {with: %r{\A(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)[a-z0-9_.-]+/[a-z0-9_.-]+\.git\z}i},
            allow_blank: true

  before_validation :set_default_https_login, :set_local_url
  before_create :clone_repository
  after_commit :register_requested_hook, on: %i[create update]

  safe_attributes 'register_hook'

  class << self
    def human_attribute_name(attribute, options = {})
      super(attribute.to_s == 'url' ? 'github_url' : attribute, options)
    end

    def scm_adapter_class
      Redmine::Scm::Adapters::GithubAdapter
    end

    def scm_name
      'GitHub.com'
    end

    def scm_available
      super && GithubCreator.configured?
    end
  end

  def register_hook
    extra_register_hook
  end

  def register_hook=(value)
    merge_extra_info('extra_register_hook' => value)
  end

  def extra_created_with_scm
    extra_boolean_attribute('extra_created_with_scm')
  end

  def extra_register_hook
    return default_register_hook if new_record? && (extra_info.nil? || !extra_info.key?('extra_register_hook'))

    extra_boolean_attribute('extra_register_hook')
  end

  def extra_hook_registered
    extra_boolean_attribute('extra_hook_registered')
  end

  def extra_report_last_commit
    true
  end

  def fetch_changesets
    with_mirror_lock do
      unless File.directory?(root_url) && scm.fetch
        record_mirror_status('error', I18n.t(:error_github_mirror_refresh_failed))
        next false
      end

      result = super
      record_mirror_status('ready', nil, fetched_at: Time.current)
      result || true
    end
  rescue StandardError => e
    Rails.logger.error "SCM Creator GitHub mirror refresh failed: #{e.message}"
    record_mirror_status('error', e.message)
    false
  end

  def clear_extra_info_of_changesets; end

  def github_webhook_secret
    extra_info&.fetch('extra_webhook_secret', nil)
  end

  def ensure_github_webhook_secret
    github_webhook_secret.presence || SecureRandom.hex(32).tap do |secret|
      merge_extra_info('extra_webhook_secret' => secret)
    end
  end

  def register_secure_hook
    response = GithubCreator.register_hook(self)
    metadata = (extra_info || {}).dup
    if response
      metadata['extra_hook_registered'] = '1'
      metadata['extra_hook_id'] = response[:id].to_s if response.respond_to?(:[])
      metadata.delete('extra_hook_error')
      update_column(:extra_info, metadata)
      true
    else
      metadata['extra_hook_error'] = I18n.t(:warning_github_hook_registration_failed)
      update_column(:extra_info, metadata)
      false
    end
  end

  def mirror_status
    extra_info&.fetch('extra_mirror_status', nil).presence || (File.directory?(root_url) ? 'ready' : 'missing')
  end

  def mirror_last_fetch_at
    parse_metadata_time('extra_mirror_last_fetch_at')
  end

  def mirror_last_error
    extra_info&.fetch('extra_mirror_last_error', nil)
  end

  def mirror_size_bytes
    extra_info&.fetch('extra_mirror_size_bytes', nil).to_i.presence
  end

  private

  def extra_boolean_attribute(name)
    value = extra_info && extra_info[name]
    value.present? && value.to_s != '0'
  end

  def default_register_hook
    value = GithubCreator.api['register_hook']
    value.to_s == 'force' || ActiveModel::Type::Boolean.new.cast(value)
  end

  def set_local_url
    return if url.blank? || GithubCreator.options.blank? || GithubCreator.options['path'].blank?

    full_name = GithubCreator.repository_full_name(url)
    mirror_name = "#{full_name.tr('/', '--')}.git" if full_name.present?
    self.root_url = File.join(GithubCreator.options['path'], mirror_name) if mirror_name
  end

  def set_default_https_login
    self.login = 'x-access-token' if url.to_s.start_with?('https://') && password.present? && login.blank?
  end

  def clone_repository
    manager = GithubMirrorManager.new(root_url)
    clone_started = false
    preflight = manager.prepare
    unless preflight[:ok]
      errors.add(:base, preflight[:error], **preflight[:options])
      throw(:abort)
    end

    if preflight[:state] == :existing
      merge_mirror_status('ready', nil, manager: manager)
      return true
    end
    clone_started = true
    if scm.clone
      merge_mirror_status('ready', nil, manager: manager)
      return true
    end

    manager.cleanup_failed_clone if clone_started
    errors.add(:base, :scm_repository_cloning_failed)
    throw(:abort)
  rescue StandardError => e
    Rails.logger.error "SCM Creator GitHub mirror creation failed: #{e.message}"
    manager&.cleanup_failed_clone if clone_started
    errors.add(:base, :scm_repository_cloning_failed)
    throw(:abort)
  end

  def register_requested_hook
    return unless extra_register_hook && !extra_hook_registered

    register_secure_hook
  end

  def with_mirror_lock
    lock_path = "#{root_url}.redmine-fetch.lock"
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        record_mirror_status('busy', I18n.t(:error_github_mirror_refresh_in_progress))
        return false
      end
      yield
    ensure
      lock.flock(File::LOCK_UN) rescue nil
    end
  end

  def merge_mirror_status(status, error, manager: GithubMirrorManager.new(root_url), fetched_at: nil)
    metadata = (extra_info || {}).dup
    metadata['extra_mirror_status'] = status
    if status == 'ready'
      size = manager.size_bytes
      metadata['extra_mirror_size_bytes'] = size.to_i.to_s if size
    end
    metadata['extra_mirror_last_fetch_at'] = fetched_at.utc.iso8601 if fetched_at
    if error.present?
      metadata['extra_mirror_last_error'] = error.to_s.truncate(500)
    else
      metadata.delete('extra_mirror_last_error')
    end
    self.extra_info = metadata
  end

  def record_mirror_status(status, error, fetched_at: nil)
    merge_mirror_status(status, error, fetched_at: fetched_at)
    update_column(:extra_info, extra_info) if persisted?
  rescue StandardError => e
    Rails.logger.warn "SCM Creator could not record GitHub mirror status: #{e.message}"
  end

  def parse_metadata_time(key)
    value = extra_info&.fetch(key, nil)
    Time.zone.parse(value) if value.present?
  rescue ArgumentError
    nil
  end
end
