# ─────────────────────────────────────────────
# Redshift Serverless — Namespace
#
# The namespace is the logical container that holds databases,
# users, and credentials. Setting db_name here causes Redshift
# to automatically create that database when the namespace
# is provisioned.
# ─────────────────────────────────────────────

resource "aws_redshiftserverless_namespace" "main" {
  namespace_name      = "default-namespace"
  db_name             = var.redshift_database_name # creates the "dev" database automatically
  admin_username      = "admin"
  admin_user_password = var.redshift_admin_password # supplied via terraform.tfvars or -var flag

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

# ─────────────────────────────────────────────
# Redshift Serverless — Workgroup
#
# The workgroup is the compute layer. It must reference the
# namespace created above. Terraform will create the namespace
# first because of the implicit dependency on
# aws_redshiftserverless_namespace.main.namespace_name.
# ─────────────────────────────────────────────

resource "aws_redshiftserverless_workgroup" "main" {
  workgroup_name = "default-workgroup"
  namespace_name = aws_redshiftserverless_namespace.main.namespace_name

  # Price-performance target: 50 is the balanced default (range 1-100).
  # Lower values favour cost; higher values favour speed.
  price_performance_target {
    level   = 50
    enabled = true
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }

  # Ensure the namespace exists before the workgroup is created.
  depends_on = [aws_redshiftserverless_namespace.main]
}
