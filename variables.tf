variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-north-1"
}

variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for EC2 instance"
  type        = string
  default     = "ami-017535a27f2ac0ce3"
}

variable "ecr_repository_name" {
  description = "ECR repository name"
  type        = string
  default     = "devsecops-app"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}
