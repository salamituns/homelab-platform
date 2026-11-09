// GHCR -> lab promoter for personal-site (ADR 0019 D4, Phase 1 package B).
//
// Timer job on the docker agent: every 15 minutes it pulls whatever GitHub Actions
// last published to GHCR, verifies the keyless signature and SPDX attestation came
// from the release workflow, re-scans with Trivy, copies the digest into the per-app
// Nexus repo, re-signs it with the LAB Cosign key, and opens a staging PR in apps-deploy
// when the digest changed. The actual work is /opt/ci-gates/promote-ghcr.sh (installed
// root-owned by the ci_agent role); this file only wires credentials.
//
// The GitHub source repo name contains the site's public domain: it arrives from the
// personal-site-source-repo credential and is never echoed to the build log.
pipeline {
  agent { label 'docker' }
  options {
    timestamps()
    // Only one run can hold the docker login / promotion PR at a time.
    disableConcurrentBuilds()
  }
  triggers { cron('H/15 * * * *') }
  stages {
    stage('promote') {
      steps {
        withCredentials([
          string(credentialsId: 'personal-site-source-repo', variable: 'SOURCE_REPO'),
          usernamePassword(credentialsId: 'nexus-push-personal-site', usernameVariable: 'NEXUS_USER', passwordVariable: 'NEXUS_PASSWORD'),
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
            SOURCE_REPO="$(printf '%s' "$SOURCE_REPO" | tr -d ' \t\r\n')"
            export SOURCE_REPO
            # The package lab-release.yml pushes: ghcr.io/<owner>/personal-site.
            export GHCR_IMAGE=personal-site
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
      // Digest resolution, signature JSON, Trivy report. Digests only, never SOURCE_REPO.
      archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
    }
    cleanup { cleanWs() }
  }
}
