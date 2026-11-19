module glorypos/cashier

go 1.24

require glorypos/shared v0.0.0

// Wails CLI menjalankan `go build` di folder ini. Replace ini membuat build tetap
// jalan walau dijalankan dengan GOWORK=off atau di luar workspace.
replace glorypos/shared => ../shared
