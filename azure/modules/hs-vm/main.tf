# ============================================================
# One Hammerspace VM (Anvil or DSX) + the setAdminPassword
# extension, mirroring the ARM template's VM resources.
#
# Uses the classic azurerm_virtual_machine resource on purpose:
# it supports inline storage_data_disk blocks, so the metadata /
# data disks exist at first boot exactly like the ARM template's
# storageProfile.dataDisks (the modern azurerm_linux_virtual_machine
# only attaches data disks after the VM is created, which races
# the Hammerspace first-boot volume discovery).
# ============================================================

locals {
  ultra_ssd = length([for d in var.data_disks : d if d.type == "UltraSSD_LRS"]) > 0

  # PremiumV2/Ultra disks cannot be declared inline in the VM's storage
  # profile with custom performance - they are created as standalone managed
  # disks (with explicit IOPS/throughput) and attached. Everything else stays
  # inline so it exists at first boot exactly like the ARM template.
  # Note: attached disks land seconds after VM creation, well before the
  # Hammerspace first-boot storage discovery runs (minutes into boot).
  perf_disks   = { for d in var.data_disks : d.lun => d if contains(["PremiumV2_LRS", "UltraSSD_LRS"], d.type) }
  inline_disks = { for d in var.data_disks : d.lun => d if !contains(["PremiumV2_LRS", "UltraSSD_LRS"], d.type) }
}

resource "azurerm_virtual_machine" "this" {
  name                             = var.name
  location                         = var.location
  resource_group_name              = var.resource_group
  network_interface_ids            = var.nic_ids
  primary_network_interface_id     = var.nic_ids[0]
  vm_size                          = var.instance_type
  availability_set_id              = var.availability_set_id
  zones                            = var.availability_zone != "" ? [var.availability_zone] : null
  proximity_placement_group_id     = var.ppg_id
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true
  tags                             = var.tags

  # Marketplace images need the purchase plan attached (ARM 'plan' block).
  dynamic "plan" {
    for_each = var.marketplace_image != null ? [var.marketplace_image] : []
    content {
      name      = plan.value.sku
      publisher = plan.value.publisher
      product   = plan.value.offer
    }
  }

  storage_image_reference {
    id        = var.marketplace_image == null ? var.image_id : null
    publisher = var.marketplace_image != null ? var.marketplace_image.publisher : null
    offer     = var.marketplace_image != null ? var.marketplace_image.offer : null
    sku       = var.marketplace_image != null ? var.marketplace_image.sku : null
    version   = var.marketplace_image != null ? var.marketplace_image.version : null
  }

  storage_os_disk {
    name              = "${var.name}OsDisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = var.os_disk_type
    disk_size_gb      = var.os_disk_size
  }

  dynamic "storage_data_disk" {
    for_each = local.inline_disks
    content {
      name              = "${var.name}DataDisk${storage_data_disk.value.lun}"
      lun               = storage_data_disk.value.lun
      create_option     = "Empty"
      caching           = "None"
      managed_disk_type = storage_data_disk.value.type
      disk_size_gb      = storage_data_disk.value.size
    }
  }

  os_profile {
    computer_name  = var.computer_name
    admin_username = var.admin_username
    admin_password = var.admin_password
    custom_data    = var.custom_data
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  # Serial-console/boot log capture - invaluable when a node never comes up.
  dynamic "boot_diagnostics" {
    for_each = var.diag_storage_uri != "" ? [1] : []
    content {
      enabled     = true
      storage_uri = var.diag_storage_uri
    }
  }

  # ARM: ultraSSDEnabled when an Ultra disk type is selected.
  additional_capabilities {
    ultra_ssd_enabled = local.ultra_ssd
  }
}

# High-performance data disks (PremiumV2/Ultra) with explicit IOPS/throughput.
resource "azurerm_managed_disk" "perf" {
  for_each = local.perf_disks

  name                 = "${var.name}DataDisk${each.value.lun}"
  location             = var.location
  resource_group_name  = var.resource_group
  storage_account_type = each.value.type
  create_option        = "Empty"
  disk_size_gb         = each.value.size
  zone                 = var.availability_zone != "" ? var.availability_zone : null
  disk_iops_read_write = each.value.iops
  disk_mbps_read_write = each.value.throughput
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "perf" {
  for_each = local.perf_disks

  managed_disk_id    = azurerm_managed_disk.perf[each.key].id
  virtual_machine_id = azurerm_virtual_machine.this.id
  lun                = each.value.lun
  caching            = "None"
}

# ARM: <vm>/setAdminPassword CustomScript extension - sets the Hammerspace
# 'admin' password (the OS admin account is not the product login).
#
# Deliberately NOT an azurerm_virtual_machine_extension resource: destroying
# that resource waits for the guest agent to uninstall the extension, which
# hangs for many minutes on a busy/half-booted node - and is pointless, since
# the extension is removed with the VM anyway. A create-only az CLI step
# means destroy never touches the guest.
resource "terraform_data" "set_admin_password" {
  triggers_replace = [azurerm_virtual_machine.this.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      f=$(mktemp)
      trap 'rm -f "$f"' EXIT
      # JSON built by python3 so the password is escaped correctly (a printf
      # format string would swallow the backslash-quotes around it).
      python3 -c 'import json, os; print(json.dumps({"commandToExecute": "ADMIN_PASSWORD=\"%s\" /usr/bin/python3.6 /usr/bin/hs-init-admin-pw" % os.environ["ADMIN_PASSWORD"]}))' > "$f"
      # Retry: right after VM creation the guest agent may not accept
      # extension operations yet (VMAgentStatusCommunicationError etc.).
      for attempt in $(seq 1 10); do
        if az vm extension set \
          --resource-group "$RG" --vm-name "$VM" \
          --name CustomScript --publisher Microsoft.Azure.Extensions \
          --version 2.0 --extension-instance-name setAdminPassword \
          --protected-settings @"$f" --output none; then
          echo "admin password set (attempt $attempt)"
          exit 0
        fi
        echo "az vm extension set failed (attempt $attempt/10) - retrying in 30s"
        sleep 30
      done
      echo "ERROR: could not set the admin password on $VM after 10 attempts" >&2
      exit 1
    EOT

    environment = {
      RG             = var.resource_group
      VM             = azurerm_virtual_machine.this.name
      ADMIN_PASSWORD = var.admin_password
    }
  }
}
