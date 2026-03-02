# ─────────────────────────────────────────────
# DATA SOURCES — reference existing Redshift resources
#
# Using "data" instead of "resource" means Terraform will READ
# these existing resources but will NOT create, modify, or delete them.
# This is the right approach when the namespace and workgroup already
# exist in your AWS account.
# ─────────────────────────────────────────────

data "aws_redshiftserverless_namespace" "main" {
  namespace_name = "default-namespace"
}

data "aws_redshiftserverless_workgroup" "main" {
  workgroup_name = "default-workgroup"
}

# ─────────────────────────────────────────────
# RESOURCE — manage Redshift Serverless workgroup
# with explicit pricing model configuration
# ─────────────────────────────────────────────

resource "aws_redshiftserverless_workgroup" "main" {
  workgroup_name = "default-workgroup"
  namespace_name = data.aws_redshiftserverless_namespace.main.namespace_name

  config {
    price_performance_target = 50  # Balanced pricing model
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

