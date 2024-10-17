resource "kubectl_manifest" "application_dapr" {
  yaml_body = templatefile("${path.module}/templates/argocd-apps/dapr.yaml", {
      GITHUB_URL = "https://dapr.github.io/helm-charts/"
    }
  )
}