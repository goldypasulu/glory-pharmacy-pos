// Package shared berisi kode yang dipakai bersama server dan aplikasi kasir:
// tipe kontrak API (docs/API_CONTRACT.md), aturan uang/qty, dan engine FIFO murni
// (tanpa akses database). Modul ini tidak boleh mengimpor server atau cashier.
package shared
