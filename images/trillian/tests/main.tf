terraform {
  required_providers {
    oci  = { source = "chainguard-dev/oci" }
    helm = { source = "hashicorp/helm" }
  }
}

variable "digests" {
  description = "The image digests to run tests over."
  type = object({
    logserver = string
    logsigner = string
  })
}

data "oci_string" "ref" {
  for_each = var.digests
  input    = each.value
}

data "oci_ref" "curl" {
  ref = "cgr.dev/chainguard/curl:latest-dev"
}

data "oci_ref" "createdb" {
  ref = "cgr.dev/chainguard/sigstore-scaffolding-trillian-createdb:latest"
}

resource "random_pet" "suffix" {}

resource "helm_release" "trillian" {
  name       = "trillian"
  repository = "https://sigstore.github.io/helm-charts"
  chart      = "trillian"
  timeout    = 600

  # TODO: properly namespace this, so we can invoke it multiple times.
  namespace        = "trillian-system"
  create_namespace = true

  // curl
  set {
    name  = "initContainerImage.curl.registry"
    value = "cgr.dev"
  }
  set {
    name  = "initContainerImage.curl.repository"
    value = "chainguard/curl"
  }
  set {
    name  = "initContainerImage.curl.version"
    value = data.oci_ref.curl.digest
  }

  // logServer
  set {
    name  = "logSigner.image.registry"
    value = data.oci_string.ref["logserver"].registry
  }
  set {
    name  = "logSigner.image.repository"
    value = data.oci_string.ref["logserver"].repo
  }
  set {
    name  = "logSigner.image.version"
    value = data.oci_string.ref["logserver"].digest
  }

  // logSigner
  set {
    name  = "logSigner.image.registry"
    value = data.oci_string.ref["logsigner"].registry
  }
  set {
    name  = "logSigner.image.repository"
    value = data.oci_string.ref["logsigner"].repo
  }
  set {
    name  = "logSigner.image.version"
    value = data.oci_string.ref["logsigner"].digest
  }

  // scaffolding createdb
  set {
    name  = "createdb.image.registry"
    value = "cgr.dev"
  }
  set {
    name  = "createdb.image.repository"
    value = "chainguard/sigstore-scaffolding-trillian-createdb"
  }
  set {
    name  = "createdb.image.version"
    value = data.oci_ref.createdb.digest
  }
}

resource "kubernetes_job_v1" "check_trillian" {
  metadata {
    name      = "check-trillian"
    namespace = helm_release.trillian.namespace
  }

  spec {
    template {
      metadata {}
      spec {
        container {
          name  = "check-coredns"
          image = "cgr.dev/chainguard/curl:latest"
          args = [
            "--retry", "10",
            "--retry-all-errors", "trillian.trillian-system:8091/metrics"
          ]
        }
        restart_policy = "Never"
      }
    }
  }

  wait_for_completion = true
}

module "helm_cleanup-trillian" {
  depends_on = [kubernetes_job_v1.check_trillian]
  source     = "../../../tflib/helm-cleanup"
  name       = helm_release.trillian.id
  namespace  = helm_release.trillian.namespace
}

data "oci_exec_test" "test" {
  digest = data.oci_string.ref["logsigner"].id
  script = "${path.module}/test.sh"

  env {
    name  = "TRILLIAN_LOG_SIGNER"
    value = data.oci_string.ref["logsigner"].id
  }

  env {
    name  = "TRILLIAN_LOG_SERVER"
    value = data.oci_string.ref["logserver"].id
  }
}
