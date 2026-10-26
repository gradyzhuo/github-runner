# github-runner

A self-hosted [GitHub Actions runner](https://github.com/actions/runner) packaged as a
Docker image. Point it at an organization or a repository, give it a PAT, and it
registers itself, runs jobs, and unregisters when the container stops.

- Register to an **organization** or a **single repository** via `GITHUB_URL`
- Labels, name, runner group and ephemeral mode via environment variables
- Docker CLI, buildx and compose included; mount the host socket to `docker build` / `docker push` from jobs
- Runs as a non-root `runner` user (passwordless `sudo` available)
- `linux/amd64` and `linux/arm64`

## Quick start

```sh
docker run -d --name gh-runner --restart unless-stopped \
  -e GITHUB_URL=https://github.com/my-org \
  -e GITHUB_PAT=ghp_xxxxxxxxxxxx \
  -e RUNNER_LABELS=docker,linux \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/gradyzhuo/github-runner:latest
```

For a single repository use `GITHUB_URL=https://github.com/my-org/my-repo`.

Stop with `docker stop gh-runner`; the runner removes itself from GitHub before exiting.

### docker compose

```sh
cp .env.example .env   # fill in GITHUB_URL and GITHUB_PAT
docker compose up -d
```

## Environment variables

| Variable           | Required | Default                 | Description |
|--------------------|----------|-------------------------|-------------|
| `GITHUB_URL`       | yes      |                         | `https://github.com/<org>` or `https://github.com/<org>/<repo>`. GitHub Enterprise Server hosts work too. |
| `GITHUB_PAT`       | yes      |                         | Personal access token used to mint registration/removal tokens. |
| `RUNNER_LABELS`    | no       |                         | Comma-separated extra labels, e.g. `docker,linux`. The runner always has `self-hosted`, `linux` and the arch. |
| `RUNNER_NAME`      | no       | container hostname      | Name shown in GitHub. An existing runner with the same name is replaced. |
| `RUNNER_GROUP`     | no       | `Default`               | Runner group (organization scope only). |
| `RUNNER_EPHEMERAL` | no       | `false`                 | `true` registers with `--ephemeral`: the runner takes one job, then the container exits. Pair with `--restart unless-stopped` for a fresh runner per job. |
| `RUNNER_WORKDIR`   | no       | `_work`                 | Job working directory, relative to `/home/runner`. |
| `GITHUB_API_URL`   | no       | derived from `GITHUB_URL` | Override the REST API base, e.g. for GHES. |
| `DOCKER_SOCK`      | no       | `/var/run/docker.sock`  | Path of the mounted Docker socket. |

### PAT scopes

| Scope of `GITHUB_URL` | Classic PAT scope | Fine-grained PAT permission |
|-----------------------|-------------------|-----------------------------|
| Organization          | `admin:org`       | Organization → Self-hosted runners: Read and write |
| Repository            | `repo`            | Repository → Administration: Read and write |

The PAT is only used to call the registration-token and remove-token endpoints.
Jobs never see it.

## Docker in jobs

Mounting `/var/run/docker.sock` lets workflows use the **host's** Docker daemon.
Build cache and images are shared with the host, and no privileged container is needed.
Any job on this runner can therefore control the host's Docker, which is
effectively host-level access. Only attach runners configured this way to repositories you trust.

```yaml
jobs:
  build:
    runs-on: [self-hosted, docker]
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t my-image .
```

## Build the image yourself

```sh
docker build -t github-runner .

# pin a runner release instead of "latest"
docker build --build-arg RUNNER_VERSION=2.321.0 -t github-runner .
```

Runner self-update is disabled inside the container (`--disableupdate`). Rebuild
the image to pick up new runner releases; the included GitHub workflow rebuilds
`latest` weekly.

## License

MIT
