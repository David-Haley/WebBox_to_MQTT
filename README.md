# WebBox_to_MQTT
This repository contains a program that reads from an SMA WebBox via remote procedure calls and publishes to an MQTT broker.

## Configuration
The WebBox host name, inverter, broker host name, user name, password and topic are read from `WebBox_to_MQTT_Configuration.json` in the current working directory. Create or edit this file with `configure_webbox_to_mqtt`; the password is stored encrypted. The inverter is identified by its WebBox device key, for example `WRTL1ECD:2100583664`.

## Operation
At startup the names of all the process data channels published by the configured inverter are read (`GetProcessDataChannels`). Each cycle then reads the plant overview (`GetPlantOverview`) followed by the inverter's process data (`GetProcessData`). Remote procedure calls are at least 30 s apart, the minimum interval recommended in the SMA manual, so a message is published every 60 s. A message is only published if both calls in the cycle succeed.

The published message is a flat JSON object containing:
- `power` and `daily_yeild` — the current plant power output and daily yield from the plant overview;
- every inverter channel as `"Name":"ValueUnit"`, for example `"Pac":"177W"`;
- `message_time_utc` — the UTC time the inverter process data was received.

Only one instance should be run on a machine, as instances share the WebBox RPC port.

## Build
`gprbuild -P webbox_to_mqtt.gpr` with the `Pi_Common` and `DJH` repositories checked out alongside this one. The executables `webbox_to_mqtt` and `configure_webbox_to_mqtt` are built in `bin/`.
