# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

WebBox_to_MQTT is an Ada program that polls an SMA WebBox solar inverter gateway
via UDP remote procedure call (a JSON payload over a proprietary `RPC=` framing),
extracts the current grid power (`GriPwr`) and daily yield (`GriEgyTdy`), and
publishes them as JSON to an MQTT broker every 30 seconds (the minimum interval
recommended by the SMA manual).

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
(`WebBox, Broker, User, Password, Topic`) and which of them are stored
encrypted (`Password` only). This enum is passed as a generic parameter to
`DJH.JSON_Configuration`, instantiated separately in each main program
(`webbox_to_mqtt.adb` and `configure_webbox_to_mqtt.adb`), which reads/writes
`WebBox_to_MQTT_Configuration.json` next to the executable. Run
`configure_webbox_to_mqtt` first to create this file — `webbox_to_mqtt` raises
`JSON_Configuration_Error` and exits if it's missing.

To add a new configuration field: add a value to `Parameters` in
`common_configuration.ads`, update `Encrypted` in `common_configuration.adb` if
it should be stored encrypted, and read it via `Get_Value` in `webbox_to_mqtt.adb`.

## Architecture (`src/webbox_to_mqtt.adb`)

The main program is a single procedure built around two concurrent threads of
control:

- **Main task**: on a fixed 30 s cycle (`Poll_Interval`), builds a WebBox RPC
  request (`Overview_Request`) as a `Wide_String` (the WebBox protocol expects
  UTF-16-ish wide characters prefixed with `RPC=`), sends it over a UDP socket,
  then calls `Receiver.Request_Sent` and waits for the next `delay until` tick.
- **`Receiver` task**: blocks on `Receive_Socket` (5 s timeout) for the reply to
  each request, parses the JSON response, and calls `Publish` to extract fields
  and send the result over MQTT. Any exception during receive/parse (including
  timeout) is swallowed so the polling loop is not disrupted.

Both tasks share `Client_Socket` and `Publish_Handle` as procedure-level
globals. The request/reply exchange is correlated by a `Sequence_Number`
embedded as the JSON `id` field and checked in `Publish` before publishing —
mismatched or malformed replies are silently dropped rather than raising.

Wide-string/byte-buffer conversion between the socket layer (`Stream_Element_Array`)
and the WebBox's wide-character protocol is done via `pragma Import (Ada, ...)`
address overlays (`Rx_Wide_JSON`/`Tx_Buffer`), not explicit encoding calls — be
careful with buffer sizing if touching this code.

Shutdown is cooperative: `Linux_Signals.Handlers` traps `SIGTERM`, and `Ctrl_C_Stop`
covers interactive termination; the main loop checks both after each send and,
on exit, stops the `Receiver` task, closes the socket, and disconnects MQTT. Any
unhandled exception at the top level is caught, logged, and aborts `Receiver`
before setting a failure exit status.

## Key external dependencies

- `GNATCOLL.JSON` — JSON parsing/writing (from `../Pi_Common`'s `lib_gnatcoll*.gpr`
  wrappers around a prebuilt GNATCOLL library).
- `MQTT_Client` (`../Pi_Common/src`) — thin Ada binding over libmosquitto
  (`lib_mosquitto.gpr` points at the system `libmosquitto.so`).
- `DJH.JSON_Configuration` (`../DJH/src`) — generic JSON-file-backed
  configuration store, shared across the author's other Ada projects.
