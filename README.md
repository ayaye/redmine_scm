# SCM Creator for Redmine

SCM Creator provisions repositories from Redmine and registers them with projects. Version 2.3.5 targets Redmine 6.0 and newer.

This plugin is a modernized continuation of the original [SCM Creator](https://www.redmine.org/plugins/redmine_scm) created by Andriy Lesyuk. The Redmine 6 version is maintained by [www.SaaS-Secure.com, S. Ruttloff](https://www.saas-secure.com/). See [`CREDITS`](CREDITS) for contributor attribution.

Supported providers:

- Git
- Subversion
- Mercurial
- Bazaar
- GitHub, including remote creation, a local bare mirror and optional push webhooks
- VCSAdmin Git, using the VCSAdmin read-only JSON API without a local repository copy

## Requirements

- Redmine 6.0 or newer
- The command-line client for each enabled local SCM
- A writable repository root for the Redmine application user
- Octokit 10 for GitHub support; it is declared in the plugin `Gemfile`
- GitHub SSH credentials on the Redmine host when `clone_protocol: ssh` is used

## Installation

Place the plugin in `plugins/redmine_scm`, then run from the Redmine root:

```bash
bundle install
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

Copy `plugins/redmine_scm/config/scm.yml` to `config/scm.yml`, adapt the production paths, and restart Redmine.

The migration adds `repositories.created_with_scm`. This flag distinguishes repositories whose filesystem data is managed by this plugin.

Version 2.3.0 added a small database table used only to prevent concurrent
VCSAdmin changeset synchronization.

## VCSAdmin Git

Configure each project repository with its complete VCSAdmin repository API URL
ending in `/api/v1/scm/repositories/ID`. The connector extracts the stable ID and
stores the normalized API base URL internally. No separate repository selector
or repository-list request is used. The optional `scm.yml` section contains
shared operational limits:

```yaml
production:
  vcsadmin_git:
    open_timeout: 5
    read_timeout: 20
    page_size: 25
    sync_batch_size: 25
    initial_import_batch_size: 50
    max_pages_per_sync: 3
    max_response_bytes: 6291456
    max_file_bytes: 1048576
    retry_count: 1
    verify_tls: true
```

Restart Redmine and enable `VcsadminGit` under the enabled SCM settings. A
trusted user with **Manage repository** permission can then enter the
complete repository API URL and its VCSAdmin Basic Authentication credentials.
Saving validates that exact repository. The optional connection test performs
the same direct repository access check. Passwords use
Redmine's existing ciphered repository password column; configure Redmine's
database encryption key.

The connector browses trees and text files, lists branches/tags/history, displays
commit details and complete API-provided unified diffs, and incrementally imports
normal Redmine changesets in bounded batches. It never runs local Git or creates a
clone, mirror, checkout, or temporary repository.

See [`docs/VCSADMIN_GIT.md`](docs/VCSADMIN_GIT.md) for architecture, endpoint
mapping, limits, synchronization, security, unsupported functions,
troubleshooting, manual verification, and API contract discrepancies.

## Local repository creation

Enable the required SCMs under **Administration -> Settings -> Repositories**. Users with Redmine's **Manage repository** permission can then open **Project -> Settings -> Repositories** and select **Create new local repository**.

The repository name defaults to the project identifier. For Git, the sample configuration creates bare repositories with a `.git` suffix. Subversion repositories use `svnadmin create` and are registered through a local `file://` URL.

The plugin can also offer repository creation while a project is being created:

```yaml
production:
  auto_create: true
```

Use `auto_create: force` to require a configured SCM whenever the Repository project module is enabled.

## GitHub configuration

GitHub API credentials must be provided through environment variables, not committed to `scm.yml`:

```bash
export REDMINE_SCM_GITHUB_API_TOKEN='your-token'
export REDMINE_SCM_GITHUB_ORGANIZATION='optional-organization'
```

Example configuration:

```yaml
production:
  github:
    path: /var/lib/redmine/github_mirrors
    minimum_free_space_mb: 1024
    clone_protocol: ssh
    api:
      token: <%= ENV['REDMINE_SCM_GITHUB_API_TOKEN'] %>
      organization: <%= ENV['REDMINE_SCM_GITHUB_ORGANIZATION'] %>
      register_hook: true
      open_timeout: 5
      timeout: 15
    options:
      private: true
```

Create the mirror root and grant access to the Redmine application user:

```bash
mkdir -p /var/lib/redmine/github_mirrors
chown redmine:redmine /var/lib/redmine/github_mirrors
```

The GitHub token must be able to create repositories in the selected account or organization. When webhook registration is enabled, it also needs repository webhook write access.

For SSH mirrors, configure a deploy key or machine-user SSH key for the Redmine application user and ensure `github.com` is trusted in `known_hosts`. HTTPS mirrors can use the repository login and a personal access token, but SSH avoids credentials in Git remote URLs.

Enable **GitHub** under Redmine's enabled SCM settings after restarting Redmine.

Existing GitHub repositories can be registered without a GitHub API token. Saving the repository automatically creates the local bare mirror used by Redmine.

The **Create mirror repository** action reuses an existing repository when it is accessible to the configured account. If no repository with that name exists, it creates one and then builds the mirror. The generic Redmine **Create** button is hidden for new GitHub.com repository forms so there is one clear primary action.

Use **Test GitHub connection** before saving to verify the token and, when a full repository URL is entered, access to that repository. Existing repository settings show mirror status, last successful fetch, local size and the last error. **Refresh mirror** performs an immediate protected fetch; concurrent refresh attempts are skipped.

The project repository form also accepts a repository-specific GitHub access token. It is stored through Redmine's repository credential handling and overrides `REDMINE_SCM_GITHUB_API_TOKEN` for repository creation and webhook registration. Configure Redmine's database encryption key before storing repository credentials. When a repository token is entered, new mirrors use authenticated HTTPS and default the username to `x-access-token`; without a repository token, the configured clone protocol is used.

HTTPS credentials are passed to Git through command-scoped environment configuration. They are not included in command arguments or saved in the mirror's remote URL. SSH remains a good choice for unattended mirrors when host keys and a machine-user key are managed centrally.

Before a new mirror is cloned, the plugin verifies that the target is a direct child of the configured mirror root, the root is writable and the optional minimum free-space threshold is met. A valid existing bare mirror is reused. An occupied invalid directory is never deleted automatically. A directory created by a failed new clone is cleaned up safely.

Mirror creation remains synchronous. Very large repositories can therefore keep the repository creation request open for a long time; configure web-server timeouts and storage capacity accordingly.

The `GitHub.com` SCM type supports GitHub.com only. It does not support GitLab; GitLab requires a separate adapter and API integration.

## GitHub push webhooks

SCM Creator registers a GitHub `web` push hook that calls a plugin-owned endpoint. Each repository receives a random secret and incoming payloads must pass GitHub's `X-Hub-Signature-256` verification before the mirror is refreshed.

To use it:

1. Configure Redmine's public protocol and host name.
2. Set `github.api.register_hook: true`.
3. Give the GitHub token webhook write access.

Administrators can copy the generated endpoint or use **Register secure webhook** from an existing GitHub.com repository under **Project -> Settings -> Repositories**. Existing legacy hooks can be updated with this action. The signing secret is never displayed.

## Configuration reference

| Option | Purpose |
| --- | --- |
| `deny_delete` | Prevent direct deletion of plugin-created repository registrations. |
| `auto_create` | Offer automatic creation on new projects; use `force` to require it. |
| `force_repository` | Keep the Repository module enabled on the project form. |
| `max_repos` | Maximum plugin-created repositories per project; `0` is unlimited. |
| `only_creator` | Prevent registering repositories through Redmine's normal create button. |
| `allow_add_local` | Allow registration of existing local repository paths. |
| `allow_pickup` | Attach an existing repository matching a new project identifier. |
| `github.minimum_free_space_mb` | Optional minimum free space required before starting a new GitHub mirror; `0` disables the check. |
| `pre_create`, `post_create` | Executable lifecycle scripts around repository creation. |
| `pre_delete`, `post_delete` | Executable lifecycle scripts around filesystem deletion. |

Lifecycle scripts receive these arguments:

```text
<repository path> <scm id> <project identifier>
```

Project custom fields are passed in a command-scoped environment as `SCM_CUSTOM_FIELD_<NAME>`.

## Deletion behavior

Deleting a plugin-created repository opens a confirmation page:

- Select the filesystem option to remove the Redmine registration and repository files.
- Leave it unselected to remove only the Redmine registration.

GitHub deletion removes only the local mirror. It never deletes the remote GitHub repository.

Filesystem deletion is restricted to one direct child of the configured SCM repository root.

## External repository serving

SCM Creator creates repositories but does not publish them. Configure Apache, Nginx, Git HTTP, SSH or Subversion DAV separately. The `url` setting controls the external URL displayed by Redmine.

## Compatibility notes

- The plugin uses Redmine 6 repository helpers, controllers, hooks and safe attributes.
- It no longer overrides Redmine's complete repositories settings partial.
- Repository directories are renamed after a project identifier change when they were created by the plugin and remain under the configured root.
- GitHub uses token authentication and Octokit 10. Password-based GitHub API authentication and the removed legacy GitHub `redmine` service hook are not supported.

## Tests

In a complete Redmine source checkout with the test database prepared, run:

```bash
bundle exec rails test plugins/redmine_scm/test
```

The focused tests cover credential-safe Git invocation, existing remote reuse,
mirror path preflight, signed webhook handling, VCSAdmin response validation,
path safety, remote tree/commit mapping, truncated/binary handling, protected
connection testing, repository form rendering, bounded initial/incremental
changeset import, deduplication, parent reconciliation, issue references,
password preservation and synchronization locking.

## License

SCM Creator is free software distributed under the GNU General Public License, version 2 (`GPL-2.0-only`). See [`LICENSE`](LICENSE) for the complete license text.

The original SCM Creator was created by Andriy Lesyuk. Copyright in later Redmine 6 modifications is held by their respective contributors, including Copyright (C) 2026 www.SaaS-Secure.com, S. Ruttloff. Original authorship and contributor notices must be retained when redistributing modified versions.
