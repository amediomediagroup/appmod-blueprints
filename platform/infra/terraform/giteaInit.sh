#!/bin/sh

# This script requires DOMAIN_NAME variable to be setup already
# DOMAIN_NAME is the domain name of the cluster

export DOMAIN_NAME=$(kubectl get service ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

export REPO_ROOT=$(git rev-parse --show-toplevel)
echo "Creating app repositories in gitea"
apk add gitea
apk add git
apk add openssh-client

cd ${REPO_ROOT}/applications

export PASSWORD=$(kubectl get secret gitea-credential -n gitea -o jsonpath='{.data.password}' | base64 --decode)
export USERNAME=$(kubectl get secret gitea-credential -n gitea -o jsonpath='{.data.username}' | base64 --decode)
export USER_PASS="${USERNAME}:${PASSWORD}"
export ENCODED_USER_PASS=$(echo "$USER_PASS" | tr -d \\n | base64)

curl -k -X POST "https://$DOMAIN_NAME/gitea/api/v1/admin/users/$USERNAME/repos" -H "content-type: application/json" -H "Authorization: Basic $ENCODED_USER_PASS" --data '{"name":"dotnet"}'
curl -k -X POST "https://$DOMAIN_NAME/gitea/api/v1/admin/users/$USERNAME/repos" -H "content-type: application/json" -H "Authorization: Basic $ENCODED_USER_PASS" --data '{"name":"golang"}'
curl -k -X POST "https://$DOMAIN_NAME/gitea/api/v1/admin/users/$USERNAME/repos" -H "content-type: application/json" -H "Authorization: Basic $ENCODED_USER_PASS" --data '{"name":"java"}'
curl -k -X POST "https://$DOMAIN_NAME/gitea/api/v1/admin/users/$USERNAME/repos" -H "content-type: application/json" -H "Authorization: Basic $ENCODED_USER_PASS" --data '{"name":"terraform-eks"}'

cd dotnet
git init
git config --global credential.helper store
git checkout -b main
git add .
git -c http.sslVerify=false commit -m "first commit" --no-verify
git remote add origin https://$DOMAIN_NAME/gitea/$USERNAME/dotnet.git
git -c http.sslVerify=false push -u origin main --no-verify

cd ../golang
git init
git checkout -b main
git add .
git -c http.sslVerify=false commit -m "first commit" --no-verify
git remote add origin https://$DOMAIN_NAME/gitea/$USERNAME/golang.git
git -c http.sslVerify=false push -u origin main --no-verify

cd ../java
git init
git checkout -b main
git add .
git -c http.sslVerify=false commit -m "first commit" --no-verify
git remote add origin https://$DOMAIN_NAME/gitea/$USERNAME/java.git
git -c http.sslVerify=false push -u origin main --no-verify

cd ../../platform/infra/terraform
git init
git checkout -b main
git add prod
git add dev
git add .gitignore
git add create-cluster.sh
git -c http.sslVerify=false commit -m "first commit" --no-verify
git remote add origin https://$DOMAIN_NAME/gitea/$USERNAME/terraform-eks.git
git -c http.sslVerify=false push -u origin main --no-verify

echo "Copied all repositories to Gitea"
