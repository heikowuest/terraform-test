variable "availability_zone" {
  type        = string
  default     = ""
  description = "Azure Availability Zone for the VM and zonal managed disks. Empty = regional placement."
}
