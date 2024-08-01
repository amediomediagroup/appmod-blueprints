# Dev Cluster values stored in the AWS SSM Parameter Store

data "aws_ssm_parameter" "gitops_dev_argocd_authCA" {
  name = "/gitops/dev-argocdca"
}

data "aws_ssm_parameter" "gitops_dev_argocd_authN" {
  name = "/gitops/dev-argocd-token"
}

data "aws_ssm_parameter" "gitops_dev_argocd_serverurl" {
  name = "/gitops/dev-serverurl"
}

resource "kubectl_manifest" "argocd_dev_cluster-connect" {
  yaml_body = <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: dev-cluster-argo-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: dev-cluster
  server: ${data.aws_ssm_parameter.gitops_dev_argocd_serverurl.value}
  config: |
    {
      "bearerToken": "${data.aws_ssm_parameter.gitops_dev_argocd_authN.value}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${data.aws_ssm_parameter.gitops_dev_argocd_authCA.value}"
      }
    }
YAML
}