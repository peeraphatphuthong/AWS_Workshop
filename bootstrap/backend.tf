# Chicken-and-egg: this stack creates the state bucket, so the FIRST apply used local state.
# After the bucket existed, this block was added and `terraform init -migrate-state` copied the
# local state into S3. Backend blocks cannot use variables, hence the literal values.
terraform {
  backend "s3" {
    bucket       = "aws-workshop-tfstate-525091405764-ap-southeast-2"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true # S3 native locking (Terraform >= 1.10), replaces the DynamoDB lock table
  }
}
