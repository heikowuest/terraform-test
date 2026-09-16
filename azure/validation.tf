# ============================================================
# Cross-variable input validation - fails at plan time,
# before anything is created.
# ============================================================

resource "terraform_data" "validate_inputs" {
  lifecycle {
    precondition {
      condition     = length([for set in [var.image_id != "", var.marketplace_image != null, var.image_sas_url != ""] : set if set]) == 1
      error_message = "Set exactly ONE image source: image_id (managed/SIG image resource ID), marketplace_image (Azure Marketplace), or image_sas_url (read-only blob SAS URL to a Hammerspace .vhd)."
    }

    precondition {
      condition     = !var.create_resource_group || var.location != ""
      error_message = "create_resource_group = true needs location (the region cannot be inherited from a group that does not exist yet)."
    }

    precondition {
      condition     = !var.create_resource_group || var.virtual_network_resource_group != ""
      error_message = "create_resource_group = true needs virtual_network_resource_group: the pre-existing VNet cannot live in the group being created."
    }

    precondition {
      condition     = !(var.create_resource_group && var.image_sas_url != "" && var.image_resource_group == "")
      error_message = "With create_resource_group and image_sas_url, set image_resource_group (auto-created if missing): otherwise destroy deletes the resource group INCLUDING the staged image, forcing a re-download on the next apply."
    }

    precondition {
      condition     = !local.is_ha || (length(trimspace(var.ha_subnet_name)) > 0 && !startswith(trimspace(var.ha_subnet_name), "<"))
      error_message = "ha mode needs ha_subnet_name: a dedicated HA heartbeat subnet (a /29, not shared with other instances). On Azure the heartbeat subnet IS the peer-discovery mechanism - the product's Azure provisioning has no node_index support, so single-NIC HA cannot pair (verified 2026-07-28)."
    }

    precondition {
      condition     = var.availability_zone == "" || !local.is_ha
      error_message = "availability_zone is currently supported for standalone and dsx deployments only; ha mode continues to use an availability set."
    }

    precondition {
      condition     = var.availability_zone == "" || var.availability_set_name == ""
      error_message = "availability_zone and availability_set_name are mutually exclusive."
    }

    precondition {
      condition = (
        !local.is_dsx_only
        || (length(trimspace(var.anvil_ip)) > 0 && !startswith(trimspace(var.anvil_ip), "<"))
      )
      error_message = "deployment_mode 'dsx' adds DSX node(s) to an EXISTING cluster - anvil_ip must identify it (admin_password must be that cluster's password)."
    }

    precondition {
      condition     = local.is_dsx_only ? var.dsx_count > 0 : true
      error_message = "deployment_mode 'dsx' with dsx_count = 0 would create nothing."
    }
  }
}
