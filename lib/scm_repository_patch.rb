# frozen_string_literal: true

module ScmRepositoryPatch
  extend ActiveSupport::Concern

  included do
    before_destroy :remove_scm_repository_files
  end

  private

  def remove_scm_repository_files
    return true unless created_with_scm

    interface = ScmCreator.interface(self)
    name = interface&.repository_name(root_url)
    repository_path = name && interface.existing_path(name, self)
    return true unless repository_path

    interface.execute(ScmConfig['pre_delete'], repository_path, project)
    throw(:abort) unless interface.delete_repository(repository_path)
    interface.execute(ScmConfig['post_delete'], repository_path, project)
    true
  end
end
