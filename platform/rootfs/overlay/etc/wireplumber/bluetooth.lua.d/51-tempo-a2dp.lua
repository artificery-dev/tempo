-- Tempo plays music to speakers/headphones; it has no telephony audio role.
-- Keep AVRCP for transport and volume controls, but do not register HFP/HSP.
bluez_monitor.properties["bluez5.headset-roles"] = "[ ]"
bluez_monitor.properties["bluez5.hfphsp-backend"] = "none"
-- Use AVRCP absolute volume when supported by the remote device.
bluez_monitor.properties["bluez5.enable-hw-volume"] = true

table.insert(bluez_monitor.rules, {
  matches = { { { "device.name", "matches", "bluez_card.*" } } },
  apply_properties = {
    ["bluez5.auto-connect"] = "[ a2dp_sink ]",
    ["bluez5.hw-volume"] = "[ a2dp_sink a2dp_source ]",
    ["device.profile"] = "a2dp-sink",
  },
})
