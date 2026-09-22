# frozen_string_literal: true

module ScmProjectPatch
  extend ActiveSupport::Concern

  included do
    attr_accessor :scm

    safe_attributes 'scm'
    validates :scm,
              presence: true,
              if: -> { new_record? && module_enabled?(:repository) && ScmConfig['auto_create'].to_s == 'force' }
    validate :validate_scm_repository_availability, on: :create

    after_create :create_scm_repository
    after_update :rename_scm_repository_paths, if: :saved_change_to_identifier?
  end

  private

  def create_scm_repository
    return unless scm.present? && module_enabled?(:repository) && ScmConfig['auto_create']

    repository = Repository.factory(scm)
    interface = ScmCreator.interface(scm)
    unless repository && interface&.enabled?
      Rails.logger.error "SCM Creator cannot provision unsupported SCM #{scm.inspect}"
      return
    end

    repository.project = self
    repository_path = interface.default_path(identifier)
    unless interface.local? && File.directory?(repository_path)
      interface.execute(ScmConfig['pre_create'], repository_path, self)
      result = interface.create_repository(repository_path, repository)
      unless result
        Rails.logger.error "SCM Creator failed to provision repository for project #{identifier}"
        return
      end
      repository_path = result if result.is_a?(String)
      interface.execute(ScmConfig['post_create'], repository_path, self)
      repository.created_with_scm = true
    end

    interface.init_repository(repository)
    repository.root_url = interface.access_root_url(repository_path, repository)
    repository.url = interface.access_url(repository_path, repository)
    Rails.logger.error "SCM Creator could not register repository: #{repository.errors.full_messages.join(', ')}" unless repository.save
  end

  def validate_scm_repository_availability
    return unless scm.present? && identifier.present? && module_enabled?(:repository) && ScmConfig['auto_create']

    interface = ScmCreator.interface(scm)
    unless interface&.enabled?
      errors.add(:scm, :scm_not_supported)
      return
    end
    return unless interface.local? && interface.repository_exists?(identifier)
    return if ActiveModel::Type::Boolean.new.cast(ScmConfig['allow_pickup'])

    errors.add(:base, :repository_exists_for_identifier)
  end

  def rename_scm_repository_paths
    old_identifier, new_identifier = saved_change_to_identifier
    repositories.where(created_with_scm: true).find_each do |repository|
      interface = ScmCreator.interface(repository)
      next unless interface&.local?

      old_name = interface.repository_name(repository.root_url)
      next unless old_name && interface.belongs_to_project?(old_name, old_identifier)

      suffix = old_name.delete_prefix(old_identifier)
      new_name = "#{new_identifier}#{suffix}"
      old_path = interface.existing_path(old_name, repository)
      new_path = interface.default_path(new_name)
      next unless old_path

      if File.exist?(new_path)
        Rails.logger.error "SCM Creator cannot rename repository because target exists: #{new_path}"
        next
      end

      FileUtils.mv(old_path, new_path)
      repository.update_columns(
        root_url: interface.access_root_url(new_path, repository),
        url: interface.access_url(new_path, repository)
      )
    rescue StandardError => e
      Rails.logger.error "SCM Creator failed to rename repository #{repository.id}: #{e.message}"
    end
  end
end
