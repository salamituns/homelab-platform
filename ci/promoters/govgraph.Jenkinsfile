// GHCR -> lab promoter for govgraph (ADR 0019 D4, Phase 2).
//
// Same contract as personal-site-promoter: timer on the docker agent, promote-ghcr.sh
// does the work. Per-app env: GHCR_IMAGE, DEST_IMAGE, overlay path, branch prefix.
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
          sh '''
            set -eu
            DOCKER_CONFIG="$(mktemp -d "${WORKSPACE_TMP:-/tmp}/docker-config.XXXXXX")"
            export DOCKER_CONFIG
            trap 'rm -rf "$DOCKER_CONFIG"' EXIT
            printf '%s' "$NEXUS_PASSWORD" | docker login registry.home.arpa -u "$NEXUS_USER" --password-stdin >/dev/null
            SOURCE_REPO="$(printf '%s' "$SOURCE_REPO" | tr -d ' \t\r\n')"
            export SOURCE_REPO
            export GHCR_IMAGE=govgraph
            export DEST_IMAGE=registry.home.arpa/govgraph/web
            export OVERLAY_DIR=apps/govgraph/overlays/staging
            export IMAGE_NAME=registry.home.arpa/govgraph/web
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
