# envs/dev.tfvars — non-sensitive dev environment overrides
# Sensitive values (subscription_id, tenant_id, platform_domain) come from
# TF_VAR_* secrets in CI — never put them here.

resource_name_environment = "dev"
github_environment        = "azure-hub"
repo_revision             = "main"
