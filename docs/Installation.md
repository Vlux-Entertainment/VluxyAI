---
sidebar_position: 2
---

# Installation

VluxyAI is published on [Wally](https://wally.run/).

## Wally

Add it to your project's `wally.toml` under `[dependencies]`. The package is `shared` realm, so it
can live in a folder both server and client see; only the server needs to build agents, but the
types, the runner and the scoring are safe to require anywhere.

```toml
[package]
name = "your_name/your_project"
version = "0.1.0"
registry = "https://github.com/UpliftGames/wally-index"
realm = "shared"

[dependencies]
VluxyAI = "greenviper126/vluxyai@0.2.0"
```

Run `wally install`. Wally creates a `Packages` folder holding VluxyAI and its one dependency,
[Trove](https://github.com/Sleitnick/RbxUtil/tree/main/modules/trove).

## Rojo

Sync the `Packages` folder somewhere both realms can reach:

```json
{
	"name": "your_project",
	"tree": {
		"$className": "DataModel",
		"ReplicatedStorage": {
			"$className": "ReplicatedStorage",
			"Packages": {
				"$path": "Packages"
			}
		}
	}
}
```

Then in a server script:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)
```

## Types across the package boundary

Wally's link files do not carry Luau types by default. If you want `VluxyAI.Agent`,
`VluxyAI.Brain` and friends to resolve in your editor, run
[wally-package-types](https://github.com/JohnnyMorganz/wally-package-types) after `wally install`:

```sh
rojo sourcemap default.project.json -o sourcemap.json
wally-package-types --sourcemap sourcemap.json Packages/
```
