BOOTINFO.R4X
============

BOOTINFO.R4X zeigt die vom Bootloader uebernommene BootInfo als normales
Terminal-/Shell-Werkzeug an.

Aufrufe:

    BOOTINFO
    BOOTINFO /SUMMARY
    BOOTINFO /FB
    BOOTINFO /MAP
    BOOTINFO /RAW
    BOOTINFO /SAVE C:\TEMP\BOOTINFO.TXT

Die Daten kommen ueber die R4DEV-Snapshot-API aus dem Kernel. Die Erfassung
bleibt damit Kernelaufgabe, Darstellung und Speicherung liegen im Userland.

Projektstruktur seit 0.51.18:
- `build.zig` baut BOOTINFO.R4X als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad und Contract.

Build:

    cd Code\System\Software\BootInfo
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\BootInfo\zig-out\BOOTINFO.R4X

Contract:
- R4XStart-Entry: `bootinfo_main`
- App-Klasse: `console`
- R4L-Import: `R4DEV:Query:1`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\BOOTINFO.R4X`
