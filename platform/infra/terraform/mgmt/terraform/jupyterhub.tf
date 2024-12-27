resource "kubernetes_manifest" "namespace_jupyterhub" {
  manifest = {
    "apiVersion" = "v1"
    "kind"       = "Namespace"
    "metadata" = {
      "name" = "jupyterhub"
    }
  }
}
resource "kubectl_manifest" "applications-argocd-jupyterhub" {
  yaml_body = templatefile("${path.module}/templates/argocd-apps/jupyterhub.yaml", {
    GITHUB_URL     = local.repo_url,
    JUPYTERHUB_URL = "https://${local.domain_name}/jupyterhub",
    KC_URL         = local.kc_url
    }
  )
}

resource "terraform_data" "jupyterhub-setup" {
  depends_on = [
    kubectl_manifest.application_argocd_keycloak,
    kubernetes_manifest.namespace_jupyterhub
  ]

  provisioner "local-exec" {
    command = "./install.sh ${local.domain_name}"

    working_dir = "${path.module}/scripts/jupyterhub"
    interpreter = ["/bin/bash", "-c"]
  }

  provisioner "local-exec" {
    when = destroy

    command = "./uninstall.sh"

    working_dir = "${path.module}/scripts/jupyterhub"
    interpreter = ["/bin/bash", "-c"]
  }
}
resource "kubectl_manifest" "ingress-jupyterhub" {
  depends_on = [kubectl_manifest.applications-argocd-jupyterhub]
  yaml_body = templatefile("${path.module}/templates/manifests/ingress-jupyterhub.yaml", {
    JUPYTERHUB_DOMAIN_NAME = local.domain_name
    }
  )
}
