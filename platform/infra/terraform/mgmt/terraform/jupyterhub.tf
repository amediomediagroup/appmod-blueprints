resource "terraform_data" "jupyterhub-setup" {
  depends_on = [
    kubernetes_manifest.namespace_gitea
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

resource "kubectl_manifest" "applications-argocd-jupyterhub" {
  yaml_body = templatefile("${path.module}/templates/argocd-apps/jupyterhub.yaml", {
    GITHUB_URL = "https://argoproj.github.io/argo-helm"
    }
  )
}

resource "kubectl_manifest" "ingress-jupyterhub" {
  yaml_body = templatefile("${path.module}/templates/manifests/ingress-jupyterhub.yaml", {
    GITHUB_URL = "https://argoproj.github.io/argo-helm"
    }
  )
}
