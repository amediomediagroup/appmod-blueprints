resource "kubectl_manifest" "application_kyverno" {
  yaml_body = templatefile("${path.module}/templates/argocd-apps/kyverno.yaml", {
      GITHUB_URL = "https://kyverno.github.io/kyverno/"
    }
  )
}

resource "kubectl_manifest" "application_kyverno_enforce" {
  depends_on = [
    kubectl_manifest.application_kyverno,
  ]
  yaml_body = templatefile("${path.module}/templates/argocd-apps/kyverno-enforce.yaml", {
    GITHUB_URL = "https://github.com/kyverno/kyverno"
  }
  )
}

resource "kubectl_manifest" "application_kyverno_enforce_exceptions" {
  depends_on = [
    kubectl_manifest.application_kyverno_enforce,
  ]
  yaml_body = templatefile("${path.module}/templates/argocd-apps/kyverno-enforce-exceptions.yaml", {
    GITHUB_URL = local.repo_url
  }
  )
}