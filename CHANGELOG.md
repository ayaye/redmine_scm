# Changelog

## 2.3.5

- Added the sanitized VCSAdmin repository display name to API error logs while retaining the stable remote repository ID.

## 2.3.4

- Allowed managed local repositories to be removed from world-writable provider roots without requiring ownership by the Redmine process.

## 2.3.3

- Simplified VCSAdmin Git setup to one complete repository API URL plus credentials.
- Removed the redundant remote repository list and selector from project settings.
- Changed connection testing and mapping validation to request the repository identified by the URL directly.

## 2.3.2

- Accept a VCSAdmin repository-detail API URL in project repository settings, automatically select its stable numeric repository ID, and store the normalized SCM API base URL.

## 2.3.1

- Changed VCSAdmin Git to store and validate the API base URL per Redmine repository instead of requiring one global URL.
- Kept `scm.yml` as an optional source of shared timeout, pagination, retry, cache and response-size defaults.
- Added the repository URL to protected connection testing and retained encrypted per-repository credentials.

## 2.3.0

- Added the VCSAdmin Git remote JSON API connector without local Git storage or command execution.
- Added protected connection testing and repository selection using VCSAdmin Basic authentication.
- Added tree, text blob, branch, tag, commit, path-history and complete unified-diff mapping.
- Added bounded, cursor-persisted default-branch changeset import with full-hash deduplication and parent reconciliation.
- Added an expiring database synchronization lock and administrative sync status.
- Added response-size, file-size, timeout, TLS, redirect, retry, path and capability safeguards.
- Added English and German UI text and detailed architecture, endpoint mapping, security and limitation documentation.

## 2.2.1

- Restored the upstream GNU GPL v2 license and original SCM Creator attribution.
- Added a credits file identifying the original author, historical contributors and current maintainer.
- Updated project documentation with licensing and provenance information.
- Added `AGENTS.md` with architecture, security, configuration and maintenance guidance.

## 2.2.0

- Kept HTTPS GitHub tokens out of Git command arguments and stored mirror remote URLs.
- Unified existing repository lookup and creation under repository-specific credentials.
- Added mirror path, write-access and optional free-space preflight checks with failed-clone cleanup.
- Added GitHub connection testing to repository settings.
- Replaced the global Redmine repository-management key webhook with per-repository signed webhooks.
- Added mirror health, local size, last fetch/error information and a protected manual refresh action.
- Added per-mirror locking to prevent overlapping refresh operations.
- Replaced JavaScript button moving and hiding with server-rendered controls and plugin-scoped styling.
- Added focused tests for GitHub credentials, reuse, mirror preflight and webhook signatures.

## 2.1.3

- Hid Redmine's generic Create button when adding a GitHub.com repository.
- Renamed the GitHub.com primary action to Create mirror repository.
- Kept other SCM repository forms and their standard actions unchanged.

## 2.1.2

- Added an administrator-only GitHub webhook URL field to existing GitHub.com repository settings.
- Added a Redmine-native copy-link action and security guidance for the repository-management key.
- Added clear feedback when repository-management web services are not configured.

## 2.1.1

- Replaced the generic HTTP 422 page with normal Redmine repository validation feedback.
- Used authenticated HTTPS for new mirrors when a repository-specific GitHub token is entered.
- Added the standard `x-access-token` HTTPS username when no GitHub username is supplied.
- Added the GitHub API error message to repository form validation feedback.
- Reused an accessible existing GitHub repository instead of failing when its name already exists.

## 2.1.0

- Added repository-specific GitHub access token editing in project repository settings.
- Added the server environment token as a fallback behind the repository-specific token.
- Kept URL sanitization isolated from encrypted repository credentials.
- Clarified that saving or creating a GitHub repository automatically creates its local Redmine mirror.
- Renamed the SCM display to GitHub.com and clarified that GitLab is not supported.
- Added dedicated GitHub repository creation and mirror button text.

## 2.0.1

- Fixed GitHub being reported as unavailable when no GitHub API token is configured.
- Allowed existing GitHub repositories to be registered when Git and the local mirror path are available.
- Added a clear repository-form note when API-based GitHub repository creation is unavailable.

## 2.0.0

- Updated plugin loading, patches, callbacks and views for Redmine 6 and Rails 7.
- Raised the minimum supported Redmine version to 6.0.
- Removed the legacy full repositories settings view override.
- Added safe YAML configuration loading and command-scoped lifecycle script environments.
- Restricted filesystem deletion to repositories directly below configured SCM roots.
- Added repository path updates after project identifier changes.
- Updated GitHub support to Octokit 10 and token authentication.
- Added GitHub organization repository creation and configurable API timeouts.
- Fixed GitHub bare mirror cloning and fetching with current Redmine Git adapters.
- Replaced the removed GitHub Redmine service hook with a current push webhook targeting Redmine's repository-management endpoint.
- Removed plaintext GitHub credentials from the deployment configuration in favor of environment variables.
- Updated English and German locale text and installation documentation.
