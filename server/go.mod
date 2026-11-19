module glorypos/server

go 1.24

require glorypos/shared v0.0.0

// Dipakai saat build tanpa workspace (GOWORK=off, mis. di Dockerfile).
// Saat go.work aktif, workspace yang menentukan.
replace glorypos/shared => ../shared
