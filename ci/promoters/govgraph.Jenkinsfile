// GHCR -> lab promoter for govgraph (ADR 0019 D4, Phase 2).
//
// Same contract as personal-site-promoter: timer on the docker agent, promote-ghcr.sh
// does the work. Per-app env: GHCR_IMAGE, GHCR_WORKFLOW, DEST_IMAGE, overlay path,
// branch prefix, PROMOTE_APP (IMAGE_NAME is derived from DEST_IMAGE by the script).
// The GitHub source repo name arrives from govgraph-source-repo and is never echoed.
pipeline {
  agent { label 'docker' }
  options {
    timestamps()
    disableConcurrentBuilds()
  }
  triggers { cron('H/15 * * * *') }
  stages {
    stage('promote') {
      steps {
        withCredentials([
          string(credentialsId: 'govgraph-source-repo', variable: 'SOURCE_REPO'),
          usernamePassword(credentialsId: 'nexus-push-govgraph', usernameVariable: 'NEXUS_USER', passwordVariable: 'NEXUS_PASSWORD'),
          file(credentialsId: 'cosign-key', variable: 'COSIGN_KEY_FILE'),
          string(credentialsId: 'cosign-password', variable: 'COSIGN_PASS'),
          usernamePassword(credentialsId: 'gitea-ci-promote', usernameVariable: 'PROMOTE_USER', passwordVariable: 'PROMOTE_TOKEN'),
        ]) {
          // Jenkins runs sh steps with /bin/sh (dash on the agent): POSIX only, no <<< or [[ ]].
          sh '''
            set -eu
            # Registry auth for crane / syft / cosign / trivy lives in a per-build
            # DOCKER_CONFIG, deleted on exit, so the Nexus push password never outlives
            # the build in the agent's ~/.docker/config.json.
            DOCKER_CONFIG="$(mktemp -d "${WORKSPACE_TMP:-/tmp}/docker-config.XXXXXX")"
            export DOCKER_CONFIG
            trap 'rm -rf "$DOCKER_CONFIG"' EXIT
            printf '%s' "$NEXUS_PASSWORD" | docker login registry.home.arpa -u "$NEXUS_USER" --password-stdin >/dev/null
            # The credential is read from a one-line file and keeps its trailing newline.
            SOURCE_REPO="$(printf '%s' "$SOURCE_REPO" | tr -d ' \\t\\r\\n')"
            export SOURCE_REPO
            # The package lab-release.yml pushes: ghcr.io/<owner>/govgraph.
            export GHCR_IMAGE=govgraph
            # The workflow whose keyless identity the promoter verifies, on refs/heads/main.
            export GHCR_WORKFLOW=lab-release.yml
            # IMAGE_NAME defaults to DEST_IMAGE in the script; no separate export.
            export DEST_IMAGE=registry.home.arpa/govgraph/web
            export OVERLAY_DIR=apps/govgraph/overlays/staging
            export PROMOTE_APP=govgraph
            export PROMOTE_BRANCH_PREFIX=govgraph
            export COSIGN_KEY="$COSIGN_KEY_FILE" COSIGN_PASSWORD="$COSIGN_PASS"
            export GITEA_PROMOTE_USER="$PROMOTE_USER" GITEA_PROMOTE_TOKEN="$PROMOTE_TOKEN"
            /opt/ci-gates/promote-ghcr.sh
          '''
        }
      }
    }
  }
  post {
    always {
      archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
    }
    success {
      script { pingPromoterWatchdog('') }
    }
    failure {
      script {
        def n = 1
        def b = currentBuild.previousBuild
        while (b != null && b.result == 'FAILURE') {
          n++
          b = b.previousBuild
          if (n >= 20) { break }
        }
        if (n >= 3) {
          pingPromoterWatchdog('/fail')
        }
      }
    }
    cleanup { cleanWs() }
  }
}

def pingPromoterWatchdog(String suffix) {
  try {
    withCredentials([string(credentialsId: 'govgraph-promoter-watchdog-url', variable: 'WD_URL')]) {
      sh '''
        set -eu
        u=$(printf '%s' "$WD_URL" | tr -d ' \t\r\n')
        curl -fsS -m 10 -o /dev/null "${u}''' + suffix + '''"
      '''
    }
  } catch (ignored) {
    echo 'promoter watchdog ping skipped (credential missing or ping failed)'
  }
}
