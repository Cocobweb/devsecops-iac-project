# ==============================================================================
# 0. Provider AWS
# ==============================================================================
provider "aws" {
  region = "eu-north-1"
}

# ==============================================================================
# 1. VPC
# ==============================================================================
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  # enable_dns_hostnames requis pour que les VPC endpoints Interface
  # résolvent correctement leurs noms DNS privés

  tags = {
    Name = "main-vpc"
  }
}

# FIX CKV2_AWS_12 : bloquer tout trafic sur le default security group du VPC
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "default-sg-locked"
  }
}

# ==============================================================================
# 2. VPC Flow Logs vers CloudWatch — FIX CKV2_AWS_11
# ==============================================================================

# KMS hors scope sandbox — clés AWS managées. CMK requise en production.
#tfsec:ignore:aws-cloudwatch-log-group-customer-key
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  #checkov:skip=CKV_AWS_158: KMS hors scope sandbox — chiffré par clés AWS managées. CMK requise en production.
  name              = "/aws/vpc/flow-logs"
  retention_in_days = 365
}

resource "aws_iam_role" "flow_logs_role" {
  name = "vpc_flow_logs_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })
}

# logs:CreateLogStream obligatoire — ressource contrainte via ARN précis, pas de wildcard réel.
#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_role_policy" "flow_logs_policy" {
  name = "vpc_flow_logs_policy"
  role = aws_iam_role.flow_logs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      #checkov:skip=CKV_AWS_290: PutLogEvents obligatoire — contrainte via ARN précis.
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = [
        "${aws_cloudwatch_log_group.vpc_flow_logs.arn}",
        "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
      ]
    }]
  })
}

resource "aws_flow_log" "vpc_flow_log" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
}

# ==============================================================================
# 3. Internet Gateway
# ==============================================================================
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "main-igw"
  }
}

# ==============================================================================
# 4. Subnets
# ==============================================================================

# Subnet public — pour Internet Gateway uniquement, aucune EC2 dans ce subnet.
# L'EC2 est dans subnet_private, ce subnet sert uniquement de point d'entrée IGW.
#tfsec:ignore:aws-ec2-no-public-ip-subnet
resource "aws_subnet" "subnet_public" {
  #checkov:skip=CKV_AWS_130: Subnet public sans EC2 — L'EC2 est dans subnet_private.
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-north-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

# Subnet privé — EC2 uniquement, pas d'IP publique
resource "aws_subnet" "subnet_private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-north-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "private-subnet"
  }
}

# ==============================================================================
# 5. Route tables
# ==============================================================================

# Route table publique — vers Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.subnet_public.id
  route_table_id = aws_route_table.public.id
}

# Route table privée — subnet EC2, pas de route internet
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-rt"
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.subnet_private.id
  route_table_id = aws_route_table.private.id
}

# ==============================================================================
# 6. VPC Endpoint S3 Gateway — layers Docker et yum sans internet
# ==============================================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.eu-north-1.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private.id
  ]

  tags = {
    Name = "s3-endpoint"
  }
}

# ==============================================================================
# 7. VPC Endpoints SSM — accès SSH-less à l'EC2
# ==============================================================================
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.eu-north-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.eu-north-1.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.eu-north-1.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg.id]
  private_dns_enabled = true
}

# ==============================================================================
# 8. VPC Endpoints ECR — docker pull depuis l'EC2 sans internet
# ==============================================================================
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.eu-north-1.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg.id]
  private_dns_enabled = true

  tags = {
    Name = "ecr-api-endpoint"
  }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.eu-north-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg.id]
  private_dns_enabled = true

  tags = {
    Name = "ecr-dkr-endpoint"
  }
}

# ==============================================================================
# 9. Security Group
# ==============================================================================

# Port 80 ouvert publiquement — serveur web public sans ALB en scope sandbox.
# Egress restreint au CIDR VPC : SSM et ECR transitent par VPC endpoints internes,
# aucune route internet depuis le subnet privé.
#tfsec:ignore:aws-ec2-no-public-ingress-sgr
resource "aws_security_group" "sg" {
  #checkov:skip=CKV_AWS_260: Port 80 ouvert publiquement — serveur web public sans ALB en scope sandbox.
  name_prefix = "web-http-only-"
  description = "Allow HTTP inbound public, HTTPS inbound VPC only, HTTPS outbound VPC only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP from anywhere (public web server)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS from internal VPC only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    description = "Allow HTTPS outbound to VPC only SSM and ECR via VPC endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
}

# ==============================================================================
# 10. IAM Role EC2 — SSM + ECR
# ==============================================================================
resource "aws_iam_role" "ssm_role" {
  name = "ec2_ssm_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Permissions ECR pour l'EC2
resource "aws_iam_role_policy" "ecr_policy" {
  name = "ec2_ecr_policy"
  role = aws_iam_role.ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ecr:GetAuthorizationToken ne supporte pas les ARN spécifiques — limitation AWS
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "arn:aws:ecr:eu-north-1:509521484299:repository/devsecops-app"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "ssm_profile"
  role = aws_iam_role.ssm_role.name
}

# ==============================================================================
# 11. EC2 Instance dans subnet privé
# ==============================================================================
resource "aws_instance" "web" {
  ami                         = "ami-017535a27f2ac0ce3"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.subnet_private.id
  vpc_security_group_ids      = [aws_security_group.sg.id]
  associate_public_ip_address = false

  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    encrypted = true
  }

  metadata_options {
    http_tokens                 = "required"  # IMDSv2 forcé — protection SSRF
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  ebs_optimized = true
  monitoring    = true

  tags = {
    Name = "web-server"
  }
}

# ==============================================================================
# 12. Random suffix pour les buckets S3
# ==============================================================================
resource "random_id" "bucket_id" {
  byte_length = 4
}

# ==============================================================================
# 13. Bucket logs
# ==============================================================================

# KMS hors scope sandbox — AES256 suffisant. CMK requise en production.
# Auto-logging non applicable : ce bucket est lui-même la destination des logs.
#tfsec:ignore:aws-s3-encryption-customer-key
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "logs_bucket" {
  #checkov:skip=CKV2_AWS_62: Event notifications hors scope.
  #checkov:skip=CKV_AWS_144: Cross-region replication hors scope sandbox.
  #checkov:skip=CKV2_AWS_61: Lifecycle hors scope — bucket de logs accessoire.
  #checkov:skip=CKV_AWS_145: KMS hors scope sandbox — AES256 suffisant.
  bucket = "devsecops-iac-project-logs-${random_id.bucket_id.hex}"
}

# FIX : chiffrement AES256 sur bucket logs
# KMS hors scope sandbox — AES256 suffisant. CMK requise en production.
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "logs_encrypt" {
  bucket = aws_s3_bucket.logs_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs_block_public" {
  bucket = aws_s3_bucket.logs_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs_versioning" {
  bucket = aws_s3_bucket.logs_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Bucket policy CloudTrail
resource "aws_s3_bucket_policy" "cloudtrail_s3_policy" {
  bucket = aws_s3_bucket.logs_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::${aws_s3_bucket.logs_bucket.id}"
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${aws_s3_bucket.logs_bucket.id}/AWSLogs/509521484299/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# ==============================================================================
# 14. Bucket principal
# ==============================================================================

# KMS hors scope sandbox — AES256 suffisant. CMK requise en production.
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket" "mybucket" {
  #checkov:skip=CKV2_AWS_62: Event notifications hors scope.
  #checkov:skip=CKV_AWS_144: Cross-region replication hors scope sandbox.
  #checkov:skip=CKV_AWS_145: KMS hors scope sandbox — AES256 suffisant.
  bucket = "devsecops-iac-project-bucket-${random_id.bucket_id.hex}"
}

resource "aws_s3_bucket_public_access_block" "block_public" {
  bucket = aws_s3_bucket.mybucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# KMS hors scope sandbox — AES256 suffisant. CMK requise en production.
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "encrypt" {
  bucket = aws_s3_bucket.mybucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.mybucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "mybucket_logging" {
  bucket        = aws_s3_bucket.mybucket.id
  target_bucket = aws_s3_bucket.logs_bucket.id
  target_prefix = "access-logs/"
}

resource "aws_s3_bucket_lifecycle_configuration" "mybucket_lifecycle" {
  bucket = aws_s3_bucket.mybucket.id

  rule {
    id     = "transition-and-expiry"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# ==============================================================================
# 15. IAM Role CloudTrail -> CloudWatch
# ==============================================================================
resource "aws_iam_role" "cloudtrail_role" {
  name = "cloudtrail_cloudwatch_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
    }]
  })
}

# logs:CreateLogStream obligatoire — ressource contrainte via ARN précis, pas de wildcard réel.
#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_role_policy" "cloudtrail_cw_policy" {
  name = "cloudtrail_cloudwatch_policy"
  role = aws_iam_role.cloudtrail_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = [
        "${aws_cloudwatch_log_group.vpc_flow_logs.arn}",
        "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
      ]
    }]
  })
}

# ==============================================================================
# 16. CloudTrail
# ==============================================================================

# KMS hors scope sandbox — CMK requise en production.
# SNS Topic hors scope sandbox.
#tfsec:ignore:aws-cloudtrail-enable-at-rest-encryption
resource "aws_cloudtrail" "main" {
  #checkov:skip=CKV_AWS_35: KMS hors scope sandbox — CMK requise en production.
  #checkov:skip=CKV_AWS_252: SNS Topic hors scope sandbox.
  name                          = "devsecops-trail"
  s3_bucket_name                = aws_s3_bucket.logs_bucket.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_role.arn

  depends_on = [aws_s3_bucket_policy.cloudtrail_s3_policy]

  tags = {
    Name = "devsecops-trail"
  }
}
