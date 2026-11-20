package store

// QueriesDB membuka koneksi transaksi milik Queries untuk tes saja.
func QueriesDB(q *Queries) DBTX { return q.db }
