PAINT.R4X
=========

PAINT.R4X ist die gehostete Desktop-Zeichen-App.

Projektstruktur seit 0.51.20:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4DESK-/R4DRAW-Imports und Contract.

Build:

    cd Code\System\Software\Paint
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\Paint\zig-out\PAINT.R4X

Contract:
- R4XStart-Entry: `paint_main`
- App-Klasse: `gui`
- R4L-Imports: `R4SYS`, `R4DESK`, `R4DRAW`, `R4NET`, `R4DEV`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\DESKTOP\PAINT.R4X`

