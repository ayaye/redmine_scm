# frozen_string_literal: true

require 'redmine'

require_relative 'lib/scm_config'
require_relative 'lib/scm_creator'
require_relative 'lib/subversion_creator'
require_relative 'lib/mercurial_creator'
require_relative 'lib/git_creator'
require_relative 'lib/bazaar_creator'
require_relative 'lib/github_creator'
require_relative 'lib/vcsadmin_git/configuration'
require_relative 'lib/vcsadmin_git/client'
require_relative 'lib/vcsadmin_git/mapper'
require_relative 'lib/redmine/scm/adapters/vcsadmin_git_adapter'
require_relative 'lib/scm_hook'
require_relative 'lib/scm_project_patch'
require_relative 'lib/scm_repository_patch'
require_relative 'lib/scm_repositories_helper_patch'
require_relative 'lib/scm_repositories_controller_patch'

Redmine::Scm::Base.add('Github')

Redmine::Plugin.register :redmine_scm do
  requires_redmine version_or_higher: '6.0'
  name 'SCM Creator'
  author 'Andriy Lesyuk; maintained by www.SaaS-Secure.com, S. Ruttloff'
  author_url 'https://www.saas-secure.com/'
  description 'Modernized continuation of SCM Creator for local SCM and GitHub repositories.'
  url 'https://github.com/ayaye/redmine_scm'
  version '2.3.5-r1'
end

apply_scm_creator_patches = proc do
  require_dependency 'project'
  require_dependency 'repository'
  require_dependency 'repositories_helper'
  require_dependency 'repositories_controller'
  require_dependency File.expand_path('app/models/repository/vcsadmin_git', __dir__)
  require_dependency File.expand_path('app/controllers/scm_vcsadmin_git_controller', __dir__)

  Project.include(ScmProjectPatch) unless Project < ScmProjectPatch
  Repository.include(ScmRepositoryPatch) unless Repository < ScmRepositoryPatch
  RepositoriesHelper.prepend(ScmRepositoriesHelperPatch) unless RepositoriesHelper < ScmRepositoriesHelperPatch
  RepositoriesController.prepend(ScmRepositoriesControllerPatch) unless RepositoriesController < ScmRepositoriesControllerPatch
  Redmine::Scm::Base.add('VcsadminGit')
end

apply_scm_creator_patches.call

if Rails.application.respond_to?(:reloader) && Rails.application.reloader.respond_to?(:to_prepare)
  Rails.application.reloader.to_prepare(&apply_scm_creator_patches)
else
  ActiveSupport::Reloader.to_prepare(&apply_scm_creator_patches)
end
