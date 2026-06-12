data "aws_region" "this" {}

locals {
  aws_region = data.aws_region.this.region
}
