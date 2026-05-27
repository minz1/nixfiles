# incus-images bucket is created by the rustfs-bucket-setup systemd service on
# minz-vultr-nix-0. Tofu only manages the bucket policy so it can apply without
# needing to first create the bucket (bootstrapping order: deploy → publish-image → apply).
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
