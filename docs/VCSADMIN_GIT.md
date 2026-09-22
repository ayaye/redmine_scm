# VCSAdmin Git connector

## Architecture and source locations

`VCSAdmin Git` is a read-only remote SCM adapter. It does not invoke local Git and
does not create a clone, mirror, checkout, temporary repository, or repository
filesystem path. Repository data is read exclusively from VCSAdmin's HTTP/JSON
API.

- Redmine plugin: `C:\redmine-6-1-plugins\httpdocs\plugins\redmine_scm`
- Read-only VCSAdmin source inspected for this implementation:
  `C:\workspace\erp\app-center\svnadmin6`
- API documentation: `SCM_API.md`
- OpenAPI document: `SCM_API.openapi.yaml`
- Authoritative implementation: `app/controllers/ScmApiController.php` and
  `library/USVN/Scm/*.php`

The connector requires VCSAdmin SCM API `v1`, Git repository support, read-only
mode, and these capabilities:

`repositories`, `branches`, `tags`, `commits`, `commit_details`, `unified_diff`,
`tree`, `text_blob`, and `path_history`.

The Redmine extension points are `Redmine::Scm::Base`,
`Redmine::Scm::Adapters::AbstractAdapter`, an STI `Repository` subclass, the
repository helper field convention, plugin controllers/routes, Redmine's
`Repository.fetch_changesets` scheduling entry point, and the standard
`Changeset`/`Change` models. No Redmine core file is changed.

## Installation and configuration

Run the normal plugin migration after installing or upgrading:

```bash
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

Migration `002` creates only the expiring, repository-specific synchronization
lock table. Connector mappings and progress use Redmine's existing repository
table.

Each VCSAdmin Git repository has its own API base URL in the project's repository
settings. The optional `config/scm.yml` section supplies only connector-wide
operational defaults:

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
    max_retry_after: 2
    verify_tls: true
    allow_http_development: false
    cache_duration: 0
```

The project form accepts one absolute repository-detail URL ending in
`/api/v1/scm/repositories/ID`. The connector extracts the numeric ID and stores
only the normalized base URL in `repository.url`; no separate repository
selector is shown. User information, query strings, and fragments are rejected.
HTTPS is mandatory except when both Rails and the explicit
`allow_http_development` option select development use. TLS verification cannot
be disabled in production. Only users with the project's **Manage repository**
permission can configure or test an API target; this permission must be limited
to trusted administrators and project managers because it authorizes outbound
requests from Redmine.

After restart, enable `VcsadminGit` under **Administration → Settings →
Repositories**. In a project's repository settings, a user with **Manage
repository** permission can enter a complete VCSAdmin repository API URL and
username/password. Saving or using the optional connection test verifies the
exact repository directly. The connector does not request or expose the account's
repository list.

Use a dedicated, non-administrator VCSAdmin account with only the repository and
path read rights Redmine requires. VCSAdmin re-evaluates its authorization on
every request; Redmine independently enforces project repository permissions.

## Mapping and credentials

Each Redmine repository maps to one stable VCSAdmin numeric project ID. The
display name and default branch are metadata only; renaming a VCSAdmin project
does not change the mapping ID.

- API base URL: repository `url`
- Username: repository `login`
- Password: repository `password`, through `Redmine::Ciphering`
- Stable remote ID: repository `root_url` and `extra_vcsadmin_repository_id`
- Display name, default branch, sync mode/progress/errors: repository
  `extra_info`
- Redmine identifier: standard repository `identifier`

The password is never put in the URL, `extra_info`, cache keys, logs, HTML, JSON
responses, synchronization state, or diagnostics. The form uses a password input
and an empty submission preserves the existing value. Actual encryption at rest
depends on Redmine's ciphering configuration; administrators must configure
Redmine's database cipher key. The plugin does not claim encryption when Redmine
is operating without that key.

## Endpoint mapping

| Redmine function | Class or method | Actual VCSAdmin endpoint | Method | Parameters | Response fields used | Limitations |
| --- | --- | --- | --- | --- | --- | --- |
| Connection/capabilities | `VcsadminGit::Client#verify!` | `/status` | GET | none | `api_version`, `available`, `repository_types`, `capabilities`, `read_only`, `limits` | Requires Basic auth |
| Connection test and mapping validation | controller test action, `Repository::VcsadminGit` / `Client#repository` | `/repositories/{repositoryId}` | GET | numeric stable repository ID extracted from the configured URL | repository identity, type, branch, capabilities, read-only flag | Hidden and nonexistent repositories are both 404; no repository-list request is made |
| Branches/default branch | `VcsadminGitAdapter#branches`, `#default_branch` | `/repositories/{repositoryId}/branches` | GET | repository ID | `name`, `commit_id`, `default` | Reference count is bounded |
| Tags | `VcsadminGitAdapter#tags` | `/repositories/{repositoryId}/tags` | GET | repository ID | `name`, `commit_id`, `date`, `tagger`, `annotated` | Redmine's selector uses the name only |
| Repository history | `VcsadminGitAdapter#revisions`, synchronization | `/repositories/{repositoryId}/commits` | GET | `revision`, optional `path`, `limit`, `cursor` | full/short IDs, parents, author, committer, dates, message, pagination | Newest-first; cursor offset ceiling applies |
| Commit details/changed files | adapter `#commit`, changeset importer | `/repositories/{repositoryId}/commits/{commitId}` | GET | route-safe commit ID | commit fields and changed `path`, type, previous path | One bounded detail request is required per imported commit; Redmine has no fields for line counts or the binary flag |
| Commit diff | `VcsadminGitAdapter#diff` | `/repositories/{repositoryId}/commits/{commitId}/diff` | GET | commit ID | format, unified text, truncation/binary flags, byte limit | Commit-wide only; truncated diffs are rejected rather than shown as complete |
| Directory browser | `VcsadminGitAdapter#entries` | `/repositories/{repositoryId}/tree` | GET | `revision`, repository-relative `path` | resolved revision and entry name/path/type/object/size | Oversized directories are errors, not partial lists |
| File content | `VcsadminGitAdapter#cat` | `/repositories/{repositoryId}/blob` | GET | `revision`, nonempty repository-relative `path` | path, revision, MIME, size, binary flag, UTF-8 content, omission reason | Text only; binary and oversized content cannot be downloaded |
| File/directory history | `VcsadminGitAdapter#revisions` | `/repositories/{repositoryId}/history` | GET | `revision`, `path`, `limit`, `cursor`, `follow_renames=false` | commit fields and pagination | Redmine adapter does not enable rename following |

All paths are repository-relative. The client rejects NULs, absolute-path
prefixes, empty/dot/traversal segments, invalid UTF-8, and paths over 4096 bytes.
It never constructs a local repository path.

## Browser behavior and API limits

Root and nested directories, branches, tags, full commit IDs, and the VCSAdmin
default branch can be browsed. Tree entry types are mapped as follows:
directories remain directories; files, symlinks, and submodules are non-directory
entries. Symlink content is available only when VCSAdmin returns its small UTF-8
target blob. Submodule content is unavailable and the connector never initializes
it.

VCSAdmin API v1 returns only valid UTF-8 text blobs. Binary and API-oversized
blobs contain metadata but no content; Redmine reports that explicitly and does
not attempt another Git transport. The local `max_file_bytes` limit applies even
when VCSAdmin permits a larger value.

Unified commit diffs come from VCSAdmin. Binary payloads are omitted by the API.
If VCSAdmin marks a diff truncated, Redmine refuses to render it and reports the
byte limit, preventing an incomplete diff from appearing complete. Arbitrary
two-revision comparisons are not supported.

## Changeset synchronization

Redmine's existing repository fetch mechanism calls
`Repository::VcsadminGit#fetch_changesets`; administrators can also run one batch
from repository settings. A scheduler may use the normal
`Repository.fetch_changesets` entry point. No complete import runs in a normal
browser request.

The strategy is default-branch only:

1. Pin a batch to the full branch-head commit ID.
2. Page newest-to-oldest with an opaque VCSAdmin cursor.
3. Retrieve bounded commit details and create normal Redmine `Changeset` and
   `Change` rows.
4. Deduplicate by full `scmid` within the repository.
5. Persist the cursor after each page.
6. Run a second bounded pass after import to connect parent associations, because
   the API pages newest-first.
7. For later runs, stop at the previous full head and import only the intervening
   history.

Each commit is saved in its own transaction; HTTP requests are not made inside a
long database transaction. An expiring database row prevents concurrent imports
for the same repository. Initial import remains browseable and restartable while
incomplete. Status, cursor, pinned head, previous boundary, last success, and a
sanitized last error are persisted.

Commit author name/email use Redmine's normal committer string and author-mapping
logic. Redmine's existing changeset callback performs issue reference and commit
keyword processing. Users are never created automatically. The API also returns
separate author/committer identities and dates; Redmine's changeset schema does
not have fields for all of them, so the importer preserves the Git author
identity and commit date in the standard fields.

Force-pushed or rewritten history does not delete already imported Redmine
changesets. If the old head is no longer reachable, bounded paging continues
toward the API pagination ceiling and deduplicates any commits still present.

## HTTP, caching, errors, and security

The client uses Ruby `Net::HTTP`, explicit connect/read timeouts, Basic
authentication headers, JSON/content-type validation, and streaming local
response-size enforcement. It never follows redirects, so credentials cannot be
forwarded to another host. At most two configured retries are permitted, with a
default of one, only for `429`, `500`, `502`, `503`, and `504`. `Retry-After`
seconds are honored only up to `max_retry_after`.

Only the successful status/capabilities response can use Rails cache, and only
when `cache_duration` is positive. Its key contains a SHA-256 identity of the
repository-specific base URL, never credentials. Repository metadata and
authorization-sensitive data are not shared-cache entries. Each client also
memoizes status for its request lifetime.

Errors distinguish configuration, DNS, refusal, connect/read timeouts, TLS,
authentication, hidden/not-found resources, revision/path validation, rate
limits, response limits, temporary service failures, incompatible v1 data,
missing capabilities, malformed JSON, and unexpected envelopes. Logs contain
only Redmine/repository IDs, operation, HTTP status, VCSAdmin machine code, and
request ID. Remote response bodies, content, diffs, credentials, authorization
headers, and stack traces are excluded.

## Unsupported functionality

VCSAdmin API v1 does not provide Git writes, repository creation/administration,
blame/annotation, arbitrary two-revision comparison, archive download, binary
download, repository statistics, or an all-branch incremental boundary. The
connector does not advertise or emulate these features through Git, SSH, smart
HTTP, dumb HTTP, or filesystem access.

## API contract discrepancies found

The implementation was treated as authoritative. Differences or material
OpenAPI omissions found during review:

1. The prose says repository IDs are opaque strings, while the route accepts only
   positive decimal IDs and converts them to integers. The connector stores the
   ID as a stable string but validates the implemented numeric grammar.
2. The prose says a commit-details ID may be another safe unambiguous Git
   revision. The actual route segment permits only `[0-9A-Za-z._-]+`; a branch or
   tag containing `/` cannot be used in that endpoint.
3. The prose error table associates `invalid_revision` with HTTP 422. The
   implementation can return code `invalid_revision` with HTTP 400 for
   syntactically rejected revisions and HTTP 422 for unresolved revisions.
4. OpenAPI uses a generic success object and does not describe the concrete
   repository, commit, tree, blob, diff, pagination, capability, or limit fields.
   The connector therefore follows controller/service response construction.
5. OpenAPI lists only selected errors per operation. The controller can also
   return the global authentication, HTTPS, method, response-size, internal, API
   disabled, Git unavailable, and Git timeout errors.
6. OpenAPI models `follow_renames` as a boolean. The implementation uses PHP
   boolean coercion; unrecognized values become false rather than producing a
   validation error.
7. `binary_files_omitted` is calculated by searching the returned diff text for
   Git's `Binary files ` marker. If that marker lies beyond a truncation boundary,
   the flag may be false even though a later binary change was omitted.

No VCSAdmin API test suite for these classes was present in the inspected source
tree.

## Troubleshooting and manual verification

- Connector absent: restart Redmine and enable `VcsadminGit`.
- Invalid configuration: confirm the URL entered for that repository is HTTPS
  and ends in `/api/v1/scm/repositories/ID`, without credentials, a query, or a
  fragment.
- Migration error during synchronization: run the plugin migration command.
- Authentication failure: use an active database or enabled LDAP VCSAdmin user;
  Entra-only web-login accounts cannot use v1 Basic authentication.
- Repository URL rejected: enter the full endpoint ending in
  `/api/v1/scm/repositories/ID`; a base URL alone is intentionally insufficient.
- TLS failure: fix trust/hostname configuration. Do not disable verification in
  production.
- Import remains incomplete: run additional bounded batches and inspect the
  server-advertised pagination limit.

With a disposable VCSAdmin account and repository, manually verify status,
repository details, root/nested tree, text/binary/oversized blobs,
branches/tags, history, changed files, normal/truncated diffs, initial and
incremental batches, repeat-run deduplication, issue references, permission
denial, timeouts, TLS failure, malformed JSON, API version, and capability
failure. Do not use production credentials in fixtures, commands, or logs.
