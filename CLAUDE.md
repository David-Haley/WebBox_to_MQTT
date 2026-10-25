# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

WebBox_to_MQTT is an Ada program that polls an SMA WebBox solar inverter gateway
via UDP remote procedure call (a JSON payload over a proprietary `RPC=` framing),
extracts the current grid power (`GriPwr`) and daily yield (`GriEgyTdy`) plus
every process-data channel of one configured inverter, and publishes them as
JSON to an MQTT broker. Remote procedure calls are at least 30 seconds apart
(the minimum interval recommended by the SMA manual), so with two calls per
cycle a message is published every 60 seconds.

## Build

This is a GNAT/GPRbuild Ada project. It depends on two sibling repositories that
must be checked out alongside this one:

- `../Pi_Common` — shared low-level packages (MQTT client, Linux signal handling,
  machine properties) plus `.gpr` wrapper projects for externally built
  libraries (`lib_mosquitto.gpr`, `lib_gnatcoll.gpr`, `lib_gnatcoll_minimal.gpr`).
- `../DJH` — general-purpose shared Ada packages (e.g. `DJH.JSON_Configuration`).

Build with:

```
gprbuild -P webbox_to_mqtt.gpr
```

This builds two executables into `bin/`:
- `webbox_to_mqtt` — the main service.
- `configure_webbox_to_mqtt` — interactive tool for creating/editing the JSON
  configuration file.

`obj/` and `bin/` are gitignored build output; there is no separate test suite
in this repository (unit tests for shared packages, if any, live in `../DJH`
and `../Pi_Common`).

Compiler switches (see `webbox_to_mqtt.gpr`) enforce `-gnat2022`, full warnings
(`-gnatwa`), validity checks (`-gnatVa`), and GNAT style checks (`-gnatyk`,
`-gnaty3`, `-gnatya`, etc.) — match existing style (3-space indent, no tabs,
`is` alone on its own line for subprogram bodies, etc.) when editing.

## Configuration

Both executables share the `Common_Configuration` package (`src/common_configuration.ads`),
which defines the set of configuration parameters as an enumeration
(`WebBox, Inverter, Broker, User, Password, Topic`) and which of them are
stored encrypted (`Password` only). `Inverter` is the WebBox device key of the
inverter to report on (e.g. `WRTL1ECD:2100583664`). No RPC `passwd` field is
sent; the WebBox has not required one for the read-only calls used. This enum
is passed as a generic parameter to `DJH.JSON_Configuration`, instantiated
separately in each main program (`webbox_to_mqtt.adb` and
`configure_webbox_to_mqtt.adb`), which reads/writes `WebBox_to_MQTT_Configuration.json` in the **current working
directory** (not next to the executable). For local testing, a configuration
file lives in `bin/Test_Area`, so run `cd bin/Test_Area && ../webbox_to_mqtt`.
Run `configure_webbox_to_mqtt` first to create this file — `webbox_to_mqtt`
raises `JSON_Configuration_Error` and exits if it's missing.

Only one instance may run at a time on a machine: the socket binds port 34268
with `Reuse_Address`, so two instances steal each other's replies (seen as
timeouts and mismatched sequence numbers).

To add a new configuration field: add a value to `Parameters` in
`common_configuration.ads`, update `Encrypted` in `common_configuration.adb` if
it should be stored encrypted, and read it via `Get_Value` in `webbox_to_mqtt.adb`.

## Architecture (`src/webbox_to_mqtt.adb`)

The main program is a single procedure built around two concurrent threads of
control:

- **Main task**: builds WebBox RPC requests as `Wide_String`s (the WebBox
  protocol expects UTF-16-ish wide characters prefixed with `RPC=`), sends
  them with `Send_Request` and collects replies with `Receive_Reply`, waiting
  `Poll_Interval` (30 s) with `delay until` between every call:
  1. At startup, `Get_Inverter_Channels` calls `GetProcessDataChannels`
     (`Channels_Request`) and fills the keys of `Inv_Field_List` (an ordered
     map of channel name → value/unit), retrying until it succeeds, then
     prints the number of channels found.
  2. Each cycle: `GetPlantOverview` (`Overview_Request`), then
     `Get_Process_Data` calls `GetProcessData` (`Process_Data_Request`, which
     asks for every key in `Inv_Field_List`) to update values and units,
     then `Publish` — only if both calls in the cycle succeeded.
- **`Receiver` task**: on each `Request_Sent` rendezvous, blocks on
  `Receive_Socket` (5 s timeout) and returns the raw reply text. Any exception
  during receive (including timeout) is swallowed so the polling loop is not
  disrupted.

`Publish` sends one flat JSON object over MQTT: `power`, `daily_yeild`,
`message_time_utc`, plus every `Inv_Field_List` entry with a value, as
`"Name":"ValueUnit"` (e.g. `"Pac":"177W"`). `message_time_utc` is the time
the `GetProcessData` reply was received; `power` and `daily_yeild` come from
the overview reply about 30 s earlier in the same cycle.

`Client_Socket`, `Webbox_Address` and `Publish_Handle` are procedure-level
globals. The request/reply exchange is correlated by a `Sequence_Number`
embedded as the JSON `id` field and checked by `Check_Sequence` in
`Receive_Reply`. `Sequence_Number` is incremented after **every** call,
successful or not, so ids are never reused across different procs. A reply
with an id lower than expected is a late reply to an earlier request still
queued on the socket: it is reported as `Stale` and `Receive_Reply` receives
again (until `Reply_Timeout` after the request) to get the current reply.
Without this, one late reply would leave every later cycle reading the
previous cycle's reply. Each reply parser also checks `proc`. Other mismatched
or malformed replies are logged and dropped rather than raising.

Wide-string/byte-buffer conversion between the socket layer (`Stream_Element_Array`)
and the WebBox's wide-character protocol is done via `pragma Import (Ada, ...)`
address overlays (`Rx_Wide_Reply` in `Receiver`, `Tx_Buffer` in
`Send_Request`), not explicit encoding calls — be careful with buffer sizing
if touching this code. The receive buffer is 65536 bytes (the largest UDP
payload, since `GetProcessData` replies are large) and lives on `Receiver`'s
stack, hence its `pragma Storage_Size`.

Shutdown is cooperative: `Linux_Signals.Handlers` traps `SIGTERM`, and `Ctrl_C_Stop`
covers interactive termination; the main loop (and the startup channel retry
loop) checks both after each remote procedure call and, on exit, stops the `Receiver` task, closes the socket, and disconnects MQTT. Any
unhandled exception at the top level is caught, logged, and aborts `Receiver`
before setting a failure exit status.

## Key external dependencies

- `GNATCOLL.JSON` — JSON parsing/writing (from `../Pi_Common`'s `lib_gnatcoll*.gpr`
  wrappers around a prebuilt GNATCOLL library).
- `MQTT_Client` (`../Pi_Common/src`) — thin Ada binding over libmosquitto
  (`lib_mosquitto.gpr` points at the system `libmosquitto.so`).
- `DJH.JSON_Configuration` (`../DJH/src`) — generic JSON-file-backed
  configuration store, shared across the author's other Ada projects.
