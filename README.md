# GitHub Actions self-hosted runner on Railway

Runs [GitHub's official Actions runner](https://github.com/actions/runner) as a
Railway service, so your workflows execute on compute you control instead of
GitHub-hosted minutes.

The image is `ghcr.io/actions/actions-runner` — GitHub's own build, pinned to a
release and bumped by Dependabot — plus a
boot script that mints the runner's registration itself. There is no registration
token to paste and nothing expires: you supply a personal access token once, and
every job gets a fresh just-in-time registration derived from it.

## Configuration

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_PAT` | yes | — | Personal access token. `repo` scope for a repository runner, `admin:org` for an organization runner. Fine-grained tokens need **Administration: read & write** (repository) or **Self-hosted runners: read & write** (organization). |
| `GITHUB_SCOPE` | yes | — | `owner/repository` for a repository runner, or `owner` for an organization runner. A pasted `https://github.com/owner/repo` URL is accepted too. |
| `RUNNER_LABELS` | no | `self-hosted,linux,x64,railway` | Labels your workflows target with `runs-on`. |
| `RUNNER_NAME_PREFIX` | no | `railway` | Runner names are `<prefix>-<replica id>`, so replicas never collide. |
| `RUNNER_NAME` | no | derived | Pin the full name instead of deriving it. Leave unset when running more than one replica. |
| `RUNNER_EPHEMERAL` | no | `true` | `true` re-registers before every job. `false` keeps one long-lived registration. |
| `RUNNER_GROUP_ID` | no | `1` | Runner group for just-in-time registration. `1` is `Default`. |
| `RUNNER_GROUP` | no | `Default` | Runner group name, used only when `RUNNER_EPHEMERAL=false`. |
| `RUNNER_WORK` | no | `/home/runner/_work` | Job workspace directory. |
| `PORT` | no | `8080` | Port the `/healthz` endpoint listens on. Railway sets this. |

## How it behaves

**Ephemeral by default.** A just-in-time registration is minted for each job, the
listener takes exactly that job, and the workspace is wiped before the next
registration. GitHub recommends this for self-hosted runners because no state
carries between jobs.

The tool cache (`RUNNER_TOOL_CACHE=/home/runner/_tool`) sits outside the workspace,
so toolchains fetched by `actions/setup-go`, `setup-node` or `setup-python` survive
the wipe and are reused until the container restarts.

The re-registration happens *inside* the container rather than by restarting it.
Recycling the container per job would spend Railway's restart budget on ordinary
CI traffic and take the service down after ten builds.

**Health check.** `/healthz` returns 200 only while GitHub reports this runner
`online`. An invalid token or a wedged listener fails the deployment instead of
sitting green over a runner that never picks up work.

**Draining.** On redeploy the runner is asked to finish its current job before
exiting. Give the service room to do that:
`RAILWAY_DEPLOYMENT_DRAINING_SECONDS=900`. The default is `0`, which kills a
running build immediately.

**Scaling.** Each replica registers under its own name, so raising the replica
count raises how many jobs run in parallel. Leave `RUNNER_NAME` unset when you do.

## Targeting the runner

```yaml
jobs:
  build:
    runs-on: self-hosted        # or any label in RUNNER_LABELS
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm test
```

Dispatch the bundled **Runner self-test** workflow to confirm the wiring.

## What does not work here

Railway containers have no Docker daemon and cannot run privileged workloads, so
these workflow features fail on this runner:

- `container:` and `services:` job keys
- `docker build` / `docker run` steps
- anything needing `sudo` beyond the image's own packages, kernel modules, or
  nested virtualisation

Ordinary language toolchain jobs — Node, Python, Go, Rust, Java, shell — run
normally. `actions/cache` works: it stores to GitHub, not to local disk.

## Security

GitHub advises using self-hosted runners with **private repositories only**. A
fork's pull request against a public repository can execute attacker-authored
code on your runner. Ephemeral mode gives each job a fresh registration and a
clean workspace, but jobs still share one container filesystem — for untrusted
code, use GitHub-hosted runners.
