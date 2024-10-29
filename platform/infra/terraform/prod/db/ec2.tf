module "ec2" {
    source      = "../../database/ec2"
    vpc_id      = var.vpc_id
    vpc_private_subnets   = var.vpc_private_subnets
    vpc_cidr    = var.vpc_cidr
    name_prefix = var.name_prefix
    key_name    = var.key_name
  }
