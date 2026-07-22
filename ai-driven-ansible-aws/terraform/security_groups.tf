# ---------------------------------------------------------------------------
# Security groups: default-deny, least-open. No 0.0.0.0/0 ingress anywhere.
# Operator access is scoped to var.allowed_ingress_cidrs; inter-node traffic
# uses SG references so it never depends on IP addresses.
# ---------------------------------------------------------------------------

resource "aws_security_group" "control" {
  name        = "${local.name_prefix}-control"
  description = "AAP control/services node (AAP, EDA, Kafka, Gitea, Mattermost)"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name_prefix}-control" }
}

resource "aws_security_group" "target" {
  name        = "${local.name_prefix}-target"
  description = "RHEL httpd target node"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name_prefix}-target" }
}

locals {
  # Operator-facing ports on the control node.
  control_ui_ports = {
    ssh        = 22
    https_aap  = 443
    gitea      = 488
    mattermost = 8065
  }
}

# --- Control node ingress from the operator ---
resource "aws_security_group_rule" "control_from_operator" {
  for_each          = local.control_ui_ports
  type              = "ingress"
  security_group_id = aws_security_group.control.id
  protocol          = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_blocks       = var.allowed_ingress_cidrs
  description       = "operator ${each.key}"
}

# Kafka is reachable ONLY from the target node (Filebeat ships httpd logs).
resource "aws_security_group_rule" "control_kafka_from_target" {
  type                     = "ingress"
  security_group_id        = aws_security_group.control.id
  protocol                 = "tcp"
  from_port                = 9092
  to_port                  = 9092
  source_security_group_id = aws_security_group.target.id
  description              = "kafka from target (filebeat)"
}

resource "aws_security_group_rule" "control_egress" {
  type              = "egress"
  security_group_id = aws_security_group.control.id
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "all egress (package + container registry pulls)"
}

# --- Target node ingress ---
resource "aws_security_group_rule" "target_ssh_from_operator" {
  type              = "ingress"
  security_group_id = aws_security_group.target.id
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = var.allowed_ingress_cidrs
  description       = "operator ssh"
}

resource "aws_security_group_rule" "target_http_from_operator" {
  type              = "ingress"
  security_group_id = aws_security_group.target.id
  protocol          = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_blocks       = var.allowed_ingress_cidrs
  description       = "operator http (view the webserver being remediated)"
}

# AAP on the control node reaches the target over SSH to run job templates.
resource "aws_security_group_rule" "target_ssh_from_control" {
  type                     = "ingress"
  security_group_id        = aws_security_group.target.id
  protocol                 = "tcp"
  from_port                = 22
  to_port                  = 22
  source_security_group_id = aws_security_group.control.id
  description              = "aap-managed ssh from control"
}

resource "aws_security_group_rule" "target_http_from_control" {
  type                     = "ingress"
  security_group_id        = aws_security_group.target.id
  protocol                 = "tcp"
  from_port                = 80
  to_port                  = 80
  source_security_group_id = aws_security_group.control.id
  description              = "httpd health checks from control"
}

resource "aws_security_group_rule" "target_egress" {
  type              = "egress"
  security_group_id = aws_security_group.target.id
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "all egress (subscription + package pulls)"
}
