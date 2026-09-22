# frozen_string_literal: true

post 'projects/:project_id/scm/github/test_connection',
     to: 'scm_github#test_connection',
     as: 'test_scm_github_connection'

post 'projects/:project_id/scm/github/repositories/:repository_id/refresh',
     to: 'scm_github#refresh_mirror',
     as: 'refresh_scm_github_mirror'

post 'projects/:project_id/scm/github/repositories/:repository_id/register_webhook',
     to: 'scm_github#register_webhook',
     as: 'register_scm_github_webhook'

post 'scm/github/webhooks/:repository_id',
     to: 'scm_github_webhooks#create',
     as: 'scm_github_webhook'

post 'projects/:project_id/scm/vcsadmin_git/test_connection',
     to: 'scm_vcsadmin_git#test_connection',
     as: 'test_scm_vcsadmin_git_connection'

post 'projects/:project_id/scm/vcsadmin_git/repositories/:repository_id/synchronize',
     to: 'scm_vcsadmin_git#synchronize',
     as: 'synchronize_scm_vcsadmin_git'
