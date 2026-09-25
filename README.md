<div align="center">

<img src="https://raw.githubusercontent.com/github/explore/main/topics/lua/lua.png" alt="Lua" width="90" height="90">

# openLuaus

**A collection of reusable modules and utilities for Luau, built for Roblox game development**

</div>

---

## About

`openLuaus` is a personal library of Luau modules designed to speed up common tasks in Roblox game development — from utility functions to reusable systems — so you don't have to reinvent the wheel on every project.

---

## ReplicatedStorage.Modules

| Module | Description |
|---|---|
| `Network` | Unified remote wrapper — one named-connection API on top of RemoteEvent, UnreliableRemoteEvent, RemoteFunction and BindableEvent, with a built-in client-ready handshake |
| `Maid` | Tracks tasks (functions, connections, threads, Instances, objects with Destroy/DoCleaning/Cleanup) and cleans them all up at once |
| `Signal` | Lightweight, allocation-friendly signal/event implementation with pooled coroutines, `:Once()`, `:Await()`, and RBXScriptSignal wrapping via `.From()` — required by `Network` |
| `SoundPlayer` | Shared audio utility for one-shot sounds and seamless looped playback with crossfading, BPM sync and queueing. Works on both server and client; every public method is error-protected and never throws |
| `Cookies` | Small leveled logger — each instance carries its own context table (merged into every entry) and its own minimum level, with pluggable output callbacks |

---

## Installation

Currently manual only — there's no Rojo/package-manager support yet.

1. Download or clone this repository.
2. Copy the module(s) you need from `ReplicatedStorage.Modules` into your own project's `ReplicatedStorage` (or wherever your module tree lives).
3. Require them as usual: `local Network = require(ReplicatedStorage.Modules.Network)`

> Rojo support (a `default.project.json` for syncing this repo directly) may be added in the future.

---

## Usage

Each module is self-contained — you can copy just the ones you need without pulling in the whole library. `Network` depends on `Signal`, so grab both if you're using the networking wrapper.

---

## Contributing

Contributions, suggestions, and improvements are welcome — feel free to open an issue or pull request.

## License

No formal license has been set yet — until one is added, treat this as free to use and reference in your own Roblox projects, with credit appreciated.
