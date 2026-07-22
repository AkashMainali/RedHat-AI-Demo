# ---------------------------------------------------------------------------
# Least-privilege instance role.
#
# The instances need NO AWS API access to run the demo. The only (optional)
# permission granted is the AWS-managed SSM core policy, which enables keyless
# Session Manager access - a safer alternative to leaving SSH open. No S3,
# no secrets access, and no broad EC2/IAM permissions are attached.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name_prefix}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_prefix}-instance" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.enable_session_manager ? 1 : 0
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name_prefix}-instance"
  role = aws_iam_role.instance.name
}
