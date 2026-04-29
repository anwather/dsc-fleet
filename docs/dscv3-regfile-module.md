# `DscV3.RegFile` module

A single class-based DSC v3 resource for bulk Windows `.reg` file imports
with idempotent verification. Source lives under
`C:\Source\dsc-fleet\modules\DscV3.RegFile\`.

```
modules\DscV3.RegFile\
├── DscV3.RegFile.psd1                   # manifest
├── DscV3.RegFile.psm1                   # GENERATED — concat of Classes\*.ps1
├── Classes\
│   └── RegFile.ps1                      # source of truth for the class
└── build\
    └── Sync-Module.ps1                  # generator + CI verify gate
```

Tests: `C:\Source\dsc-fleet\tests\Pester\DscV3.RegFile.Tests.ps1`.

## Manifest constraints

`DscV3.RegFile.psd1` declares:

```powershell
PowerShellVersion    = '7.2'
CompatiblePSEditions = @('Core')
DscResourcesToExport = @('RegFile')
```

`PowerShellVersion = '7.2'` combined with `CompatiblePSEditions = @('Core')`
means the module **can only be loaded by PowerShell 7.2+ Core**. Concretely,
this constrains how DSC v3 can host it:

| Adapter                                | Host process              | Can load `DscV3.RegFile`? |
|----------------------------------------|---------------------------|---------------------------|
| `Microsoft.DSC/PowerShell`             | `pwsh.exe` (PS 7.2+ Core) | **Yes** — required path   |
| `Microsoft.Windows/WindowsPowerShell`  | `powershell.exe` (5.1)    | **No** — manifest blocks it |

The 5.1 adapter is fine for legacy resources like `PSDscResources`'s
`MsiPackage`, but it physically cannot load this module — the manifest
gate rejects the import before any class is constructed. There is no
workaround at the DSC level; lowering `PowerShellVersion` to 5.1 would
require rewriting the class to drop type accelerators and `[byte[]]`
overloads that exist only in Core, so we deliberately keep the 7.2+
floor.

### Adapter path you must use in YAML

In any `dsc config` YAML, the resource `type` must be the
`Microsoft.DSC/PowerShell` adapter form, with the inner type set to
`DscV3.RegFile/RegFile`:

```yaml
$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json
resources:
  - name: Apply hardening reg file
    type: Microsoft.DSC/PowerShell
    properties:
      resources:
        - name: HardeningBaseline
          type: DscV3.RegFile/RegFile
          properties:
            Path:   '\\fileserver\baseline\hardening.reg'
            Hash:   '8B6F...AB12'         # optional SHA256 of the .reg
            Ensure: Present
```

If you accidentally write `type: DscV3.RegFile/RegFile` at the top level
(no adapter) or under `Microsoft.Windows/WindowsPowerShell`, `dsc config`
will report the resource as not found.

## The `RegFile` resource

| Property         | Direction        | Notes                                                                |
|------------------|------------------|----------------------------------------------------------------------|
| `Path`           | Key, in          | Local or UNC path to the `.reg` file.                                |
| `Hash`           | in (optional)    | SHA256 of the `.reg` contents. Mismatch throws (anti-tamper guard).  |
| `Ensure`         | in               | `Present` (default) or `Absent`.                                     |
| `ActualHash`     | out (read only)  | The SHA256 the resource actually saw.                                |
| `ValuesChecked`  | out (read only)  | Number of value lines parsed from the `.reg`.                        |
| `ValuesMatching` | out (read only)  | Of those, how many match the live registry.                          |

### Method semantics

* `Get()` — parses the `.reg`, reads each target value from the live
  registry, returns counts. Does not throw on missing file (returns
  zeros so `dsc resource get` can report cleanly).
* `Test()` — throws if `Path` is unreachable or if `Hash` is set and
  doesn't match. For `Ensure=Present`, returns `$true` only when every
  parsed value matches the live registry. For `Ensure=Absent`, returns
  `$true` only when none of the values listed in the `.reg` exist.
* `Set()` — for `Present`, runs `reg.exe import "<Path>"`; non-zero exit
  throws. For `Absent`, walks the parsed entries and removes each named
  value. Default-value (`@=`) entries are cleared but never auto-delete
  the surrounding key.

## `.reg` parser — value types

The parser (`[RegFile]::ParseValueLine`) maps each `.reg` value line to a
typed entry whose `Value` matches the primitive that
`Get-ItemProperty` returns for that registry type, so the comparison in
`RegistryValueMatches` is a direct equality.

| `.reg` syntax                          | Registry type     | Parsed `Type`     | `Value` shape         |
|----------------------------------------|-------------------|-------------------|-----------------------|
| `"Name"="abc"`                         | `REG_SZ`          | `String`          | `[string]`            |
| `"Name"=dword:00000001`                | `REG_DWORD`       | `DWord`           | `[int]`               |
| `"Name"=qword:00000000186600b1`        | `REG_QWORD`       | `QWord`           | `[long]`              |
| `"Name"=hex(b):00,00,60,86,b1,01,00,00`| `REG_QWORD`       | `QWord`           | `[long]` (LE-decoded) |
| `"Name"=hex:de,ad,be,ef`               | `REG_BINARY`      | `Binary`          | `[byte[]]`            |
| `"Name"=hex(0):de,ad,be,ef`            | `REG_NONE`/binary | `Binary`          | `[byte[]]`            |
| `"Name"=hex(2):25,00,54,00,...`        | `REG_EXPAND_SZ`   | `ExpandString`    | `[string]` (literal)  |
| `"Name"=hex(7):61,00,...,00,00`        | `REG_MULTI_SZ`    | `MultiString`     | `[string[]]`          |
| `"Name"=-`                             | (deletion mark)   | `DELETE`          | `$null`               |
| `@="..."`                              | default value     | `String`          | empty `Name`          |

Other `.reg` quirks the parser handles:

* UTF-16 LE BOM (the typical regedit export) — read via
  `[System.IO.File]::ReadAllLines`, which sniffs the BOM.
* Line continuations: a trailing `\` joins the next line, with the
  continuation's leading whitespace trimmed.
* `[-HKEY_...\Subkey]` (key deletion) — currently skipped; only
  value-level operations are modelled.
* Comments (`;`) and the `Windows Registry Editor Version 5.00` /
  `REGEDIT4` headers — ignored.

### What changed in 0.3.0

Versions ≤ 0.2.x had a single fall-through for any `hex(*)` form: the
bytes were stuffed into a `Binary` entry. That broke three real
scenarios:

* `hex(b)` (`REG_QWORD`) — `RegistryValueMatches` would compare a
  `[byte[]]` from the `.reg` to a `[long]` from the registry and throw
  on the cast. Every `.reg` exported from regedit that contained a
  `REG_QWORD` made `Test()` throw rather than return a result.
* `hex(2)` (`REG_EXPAND_SZ`) — the comparison was byte-vs-string and
  silently mismatched. Worse, when the live value was eventually read
  via `Get-ItemProperty`, env-var expansion meant a `.reg` literal of
  `%TEMP%\foo` could never match the runtime-expanded
  `C:\Users\…\AppData\Local\Temp\foo` — so even after a "successful"
  import the resource reported drift forever.
* `hex(7)` (`REG_MULTI_SZ`) — same byte-vs-`string[]` mismatch; `Test()`
  would always return `$false`.

0.3.0 (current) decodes each hex form to the typed primitive the
registry actually stores. For `ExpandString`, comparison reads the
unexpanded literal via
`Microsoft.Win32.RegistryValueOptions::DoNotExpandEnvironmentNames`
(`[RegFile]::ReadRawString`) so we compare the on-disk literal — the
`%TEMP%` lie is gone.

The Pester suite has explicit cases for each of these regressions
(see `RegFile.ParseValueLine — typed hex(*) decoding` and
`RegFile.RegistryValueMatches — typed registry compare (HKCU scratch)`
describes in `tests\Pester\DscV3.RegFile.Tests.ps1`).

## Build flow — `build\Sync-Module.ps1`

`DscV3.RegFile.psm1` is **generated**. Do not hand-edit it. The header
banner at the top of the file states this. The generator works because
the DSC v3 PowerShell adapter discovers `[DscResource()]`-decorated
classes by parsing the `.psm1` AST — and a class loaded via
`. <path>\Classes\RegFile.ps1` (dot-sourcing) is invisible to that scan.
Anything that isn't a textual `class …` declaration directly inside the
`.psm1` is not a DSC resource.

So we keep the developer experience clean by editing
`Classes\RegFile.ps1`, then regenerate the `.psm1` by running:

```powershell
pwsh -File modules\DscV3.RegFile\build\Sync-Module.ps1
```

The script emits a fixed header (sets `ErrorActionPreference`,
`StrictMode`, declares the shared `Ensure` enum), then concatenates each
file in `Classes\` (alphabetically) under a `# Classes\<name>.ps1`
banner. Output is UTF-8 with BOM, written to
`modules\DscV3.RegFile\DscV3.RegFile.psm1`.

### `-Verify` (CI gate)

```powershell
pwsh -File modules\DscV3.RegFile\build\Sync-Module.ps1 -Verify
```

In verify mode the script computes what the `.psm1` *should* be from
the current `Classes\` files, normalises line endings + trailing
whitespace, and compares to the on-disk `.psm1`. If they differ, it
writes an error and exits `1`. CI (`.github\workflows\ci.yml`) runs
this; a PR that edits `Classes\RegFile.ps1` without regenerating the
`.psm1` is rejected.

## Install paths

The bootstrap installer (`bootstrap\Install-DscV3.ps1`) copies the entire
`modules\DscV3.RegFile\` directory to **both** AllUsers module roots so
either edition can find it:

```
C:\Program Files\WindowsPowerShell\Modules\DscV3.RegFile\   # PS 5.1 path
C:\Program Files\PowerShell\Modules\DscV3.RegFile\          # PS 7+ path
```

In practice only the PS 7 path is loaded (the manifest blocks 5.1) — the
WindowsPowerShell copy is there because `Microsoft.PowerShell.PSResourceGet`
and other PS 5.1-installed modules also live in that root and we don't
want a half-installed AllUsers tree.

`Install-DscV3.ps1` also deletes the legacy `DscV3.Discovery` directory
from both roots if it's still around, and clears
`$env:LOCALAPPDATA\dsc\PSAdapterCache.json` so the adapter rescans on
the next `dsc resource list`.

## Local test loop

```powershell
# Regenerate after editing Classes\RegFile.ps1
pwsh -File .\modules\DscV3.RegFile\build\Sync-Module.ps1

# Verify the generator gate (what CI runs)
pwsh -File .\modules\DscV3.RegFile\build\Sync-Module.ps1 -Verify

# Run the Pester suite (mirrors the CI invocation)
pwsh -Command "Invoke-Pester ./tests/Pester -CI"
```

The `-CI` flag enables Pester's CI output mode and a non-zero exit on
test failure. The HKCU scratch-key tests use
`HKCU:\Software\DscV3.RegFile.Tests` and clean themselves up in
`AfterAll`; they do not require an elevated session.

To exercise the resource end-to-end against `dsc.exe`:

```powershell
# Sanity-check that DSC sees the resource via the adapter
dsc resource list --adapter Microsoft.DSC/PowerShell |
    Where-Object { $_.type -eq 'DscV3.RegFile/RegFile' }

# Apply a tiny config
@'
$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json
resources:
  - name: scratch
    type: Microsoft.DSC/PowerShell
    properties:
      resources:
        - name: Test
          type: DscV3.RegFile/RegFile
          properties:
            Path:   C:\path\to\test.reg
            Ensure: Present
'@ | Set-Content -LiteralPath .\test.dsc.yaml -Encoding utf8

dsc config test --file .\test.dsc.yaml --output-format json
dsc config set  --file .\test.dsc.yaml --output-format json
```
