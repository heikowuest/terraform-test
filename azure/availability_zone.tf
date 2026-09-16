# Optional Availability Zone placement for standalone / test deployments.
# Empty keeps the existing regional / availability-set behaviour.
variable "availability_zone" {
  type        = string
  default     = ""
  description = "Azure Availability Zone for Anvil and DSX VMs. Empty = existing regional placement."

  validation {
    condition     = contains(["", "1", "2", "3"], var.availability_zone)
    error_message = "availability_zone must be empty or one of: 1, 2, 3."
  }
}
