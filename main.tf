resource "digitalocean_vpc" "production" {
  name     = "production-${var.region}"
  region   = var.region
  ip_range = "10.10.10.0/24"
}

data "digitalocean_kubernetes_versions" "production" {
  version_prefix = "1.21."
}

resource "digitalocean_kubernetes_cluster" "production" {
  name          = "production-k8s-${var.region}"
  region        = var.region
  auto_upgrade  = true
  surge_upgrade = true
  version       = data.digitalocean_kubernetes_versions.production.latest_version
  vpc_uuid      = digitalocean_vpc.production.id

  maintenance_policy {
    start_time = "05:00"
    day        = "monday"
  }

  node_pool {
    name       = "default"
    size       = "s-1vcpu-2gb"
    node_count = 5
  }
}

provider "kubernetes" {
  host  = digitalocean_kubernetes_cluster.production.endpoint
  token = digitalocean_kubernetes_cluster.production.kube_config[0].token
  cluster_ca_certificate = base64decode(
    digitalocean_kubernetes_cluster.production.kube_config[0].cluster_ca_certificate
  )
}

provider "kubectl" {
  host  = digitalocean_kubernetes_cluster.production.endpoint
  token = digitalocean_kubernetes_cluster.production.kube_config[0].token
  cluster_ca_certificate = base64decode(
    digitalocean_kubernetes_cluster.production.kube_config[0].cluster_ca_certificate
  )
  load_config_file = false
}

locals {
  known_hosts = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDCK2wrQVoKKtf9MTU7fYTjNCyhBhDnHswQIMbXkYuTC1DaRE+kN2L2aV/g+0J8rVrtRFlovIzFJNTNdR9l9oiID3g1d0woZahIpS6pcDhLMR38EoAyaEhZOC73+cTFtxW38bVU10apIJB0dVOygir7YuUI6277+nVFMjbptykaQ65gUO8DmxkiusUF810K5HPSPe9e4FmLnqB8AoqPIN4+pZXjtSd+6cqsKWaULVoPkF4XmjtPy1AYUJ51yN5tFCNqKpMBKiN9WUXzFK/LM+alVDLbx+cb6pRQayobmuai4GnRao+nuynB423AevfrdKOJxFBT+WhF8e5UwroJD0fc3AUUjpdUYmZHmwJY/mdn6OPNsB+AM3wnQLWuki97BKCCv2SncyzRQ+/Kw/L5B2FMU5SMVtUM+Txawx8zNuM5kehh2MCWdjvliHMn99abqIyXzC5wA33bZoZnrwDFYtDaAmLwlIpzJHK0ljdeHIpEcP9sugyKO+rMg1Uatph9dSRv92OTE+EaZoPDqV6hkWoOIRIYEwNpSLNSzvl13pMGPvph/BYlPk2ec9qei/rVqM21DEl9I7Q97ZuE3dWXMVe98Uv0fdtq1KlNttivGH8X2yi18WYa6d1YYzoEc95vKjj/IXdbKhNKcmGVo4C4EVr0KzizQoYG/Ea+sCJZrTOJlQ=="
}

resource "tls_private_key" "main" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Flux
data "flux_install" "main" {
  target_path = var.target_path
}

data "flux_sync" "main" {
  target_path = var.target_path
  url         = "https://github.com/${var.github_owner}/${var.repository_name}.git"
  branch      = var.branch
}

# Kubernetes
resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
    ]
  }
}

data "kubectl_file_documents" "install" {
  content = data.flux_install.main.content
}

data "kubectl_file_documents" "sync" {
  content = data.flux_sync.main.content
}

locals {
  install = [for v in data.kubectl_file_documents.install.documents : {
    data : yamldecode(v)
    content : v
    }
  ]
  sync = [for v in data.kubectl_file_documents.sync.documents : {
    data : yamldecode(v)
    content : v
    }
  ]
}

resource "kubectl_manifest" "install" {
  for_each   = { for v in local.install : lower(join("/", compact([v.data.apiVersion, v.data.kind, lookup(v.data.metadata, "namespace", ""), v.data.metadata.name]))) => v.content }
  depends_on = [kubernetes_namespace.flux_system]
  yaml_body  = each.value
}

resource "kubectl_manifest" "sync" {
  for_each   = { for v in local.sync : lower(join("/", compact([v.data.apiVersion, v.data.kind, lookup(v.data.metadata, "namespace", ""), v.data.metadata.name]))) => v.content }
  depends_on = [kubernetes_namespace.flux_system]
  yaml_body  = each.value
}

resource "kubernetes_secret" "main" {
  depends_on = [kubectl_manifest.install]

  metadata {
    name      = data.flux_sync.main.secret
    namespace = data.flux_sync.main.namespace
  }

  data = {
    identity       = tls_private_key.main.private_key_pem
    "identity.pub" = tls_private_key.main.public_key_pem
    known_hosts    = local.known_hosts
  }
}

resource "github_repository_deploy_key" "main" {
  title      = "production"
  repository = "fleet-infra"
  key        = tls_private_key.main.public_key_openssh
  read_only  = true
}
