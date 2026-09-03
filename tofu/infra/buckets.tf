# incus-images bucket is created by rustfs-bucket-setup on minz-vultr-nix-0; Tofu only manages the policy so apply doesn't need the bucket to exist first (bootstrap order: deploy → publish-image → apply).
resource "aws_s3_bucket_policy" "incus_images_public_read" {
  bucket = "incus-images"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "arn:aws:s3:::incus-images/*"
      }
    ]
  })
}
