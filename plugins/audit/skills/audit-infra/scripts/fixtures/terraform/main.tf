# FIXTURE, deliberately insecure. Do not apply. Detection targets for `trivy config`:
# a public unencrypted bucket, a security group open to the world on SSH and
# PostgreSQL, an unencrypted publicly accessible database, a wildcard IAM policy.

resource "aws_s3_bucket" "uploads" {
  bucket = "audit-infra-fixture-uploads"
  acl    = "public-read"
}

resource "aws_security_group" "wide_open" {
  name   = "wide-open"
  vpc_id = "vpc-00000000"

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "PostgreSQL from anywhere"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "main" {
  identifier              = "fixture-db"
  engine                  = "postgres"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  username                = "app"
  manage_master_user_password = true
  publicly_accessible     = true
  storage_encrypted       = false
  backup_retention_period = 0
  multi_az                = false
  skip_final_snapshot     = true
}

resource "aws_iam_policy" "everything" {
  name = "everything"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "*"
      Resource = "*"
    }]
  })
}
