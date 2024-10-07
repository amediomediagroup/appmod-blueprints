variable "aws_region" {
  description = "AWS Region"
  type        = string
  default = "us-west-2"
}

variable "tfe_project" {
  description = "Unique project name for terraform lock file"
  type        = string
  default = "eks-accelerator"
}
